from fastapi import APIRouter, Request, HTTPException
from fastapi.responses import JSONResponse
from .database import get_user_info, update_user_info, get_db_connection
from .proxy import proxy_request
import sqlite3
from datetime import datetime, timedelta

router = APIRouter()

# SRS stages (based on Wanikani)
SRS_STAGES = {
    0: "initiate",
    1: "apprentice I",
    2: "apprentice II",
    3: "apprentice III",
    4: "apprentice IV",
    5: "guru I",
    6: "guru II",
    7: "master",
    8: "enlightened",
    9: "burned"
}

# SRS intervals in hours
SRS_INTERVALS = {
    0: 0,      # initiate
    1: 2,      # apprentice I
    2: 4,      # apprentice II
    3: 8,      # apprentice III
    4: 24,     # apprentice IV
    5: 48,     # guru I
    6: 168,    # guru II (7 days)
    7: 720,    # master (30 days)
    8: 4320,   # enlightened (180 days)
    9: None    # burned (no more reviews)
}

@router.get("/user")
async def get_user(request: Request):
    """Get user information (proxied for now to see format)"""
    path = "/user"
    response = await proxy_request(request, path)
    
    # Override level to 1
    if "data" in response:
        response["data"]["level"] = 1
    
    return response

@router.get("/subjects")
async def get_subjects(request: Request):
    """Get subjects (proxied, but filtered by level)"""
    user_info = get_user_info()
    current_level = user_info.get("level", 1)
    
    # Proxy the request to Wanikani
    path = "/subjects"
    response = await proxy_request(request, path)
    
    # Filter subjects by current level
    if "data" in response:
        filtered_data = [
            subject for subject in response["data"]
            if subject["data"]["level"] <= current_level
        ]
        response["data"] = filtered_data
    
    return response

@router.get("/subjects/{subject_id}")
async def get_subject(subject_id: int, request: Request):
    """Get specific subject (proxied)"""
    path = f"/subjects/{subject_id}"
    return await proxy_request(request, path)

@router.get("/assignments")
async def get_assignments(request: Request):
    """Get assignments (proxied and filtered by level 1)"""
    # Proxy the request to Wanikani
    path = "/assignments"
    response = await proxy_request(request, path)
    
    # Filter assignments to only show level 1
    if "data" in response:
        filtered_data = [
            assignment for assignment in response["data"]
            if assignment["data"]["level"] == 1
        ]
        response["data"] = filtered_data
        response["total_count"] = len(filtered_data)
    
    return response

@router.get("/reviews")
async def get_reviews(request: Request):
    """Get reviews (proxied and filtered by level 1 assignments)"""
    # First get assignments filtered by level 1
    path = "/assignments"
    assignments_response = await proxy_request(request, path)
    
    # Filter to level 1 assignments
    level_1_assignments = []
    if "data" in assignments_response:
        level_1_assignments = [
            assignment for assignment in assignments_response["data"]
            if assignment["data"]["level"] == 1
        ]
    
    # Now get reviews and filter by level 1 assignments
    path = "/reviews"
    response = await proxy_request(request, path)
    
    if "data" in response:
        assignment_ids = set(a["id"] for a in level_1_assignments)
        filtered_data = [
            review for review in response["data"]
            if review["data"]["assignment_id"] in assignment_ids
        ]
        response["data"] = filtered_data
        response["total_count"] = len(filtered_data)
    
    return response

@router.post("/reviews")
async def create_review(request: Request):
    """Submit a review (custom - updates local SRS)"""
    data = await request.json()
    review_data = data.get("review", {})
    
    assignment_id = review_data.get("assignment_id")
    subject_id = review_data.get("subject_id")
    
    # Get current assignment
    conn = get_db_connection()
    cursor = conn.cursor()
    cursor.execute("SELECT * FROM assignments WHERE id = ?", (assignment_id,))
    assignment = cursor.fetchone()
    
    if not assignment:
        conn.close()
        raise HTTPException(status_code=404, detail="Assignment not found")
    
    # Calculate new SRS stage based on correctness
    current_srs = assignment["srs_stage"]
    meaning_correct = review_data.get("meaning_correct", False)
    reading_correct = review_data.get("reading_correct", False)
    
    # Simple SRS logic: if both correct, advance; otherwise, drop back
    if meaning_correct and reading_correct:
        new_srs = min(current_srs + 1, 9)
    else:
        new_srs = max(current_srs - 1, 0)
    
    # Calculate next available time
    interval_hours = SRS_INTERVALS.get(new_srs, 0)
    if interval_hours:
        available_at = (datetime.utcnow() + timedelta(hours=interval_hours)).isoformat()
    else:
        available_at = None
    
    # Update assignment
    cursor.execute("""
        UPDATE assignments
        SET srs_stage = ?, available_at = ?
        WHERE id = ?
    """, (new_srs, available_at, assignment_id))
    
    # Update review statistics
    cursor.execute("""
        INSERT OR REPLACE INTO review_statistics
        (subject_id, subject_type, meaning_correct, meaning_incorrect, 
         reading_correct, reading_incorrect)
        VALUES (?, ?, ?, ?, ?, ?)
    """, (
        subject_id,
        assignment["subject_type"],
        1 if meaning_correct else 0,
        0 if meaning_correct else 1,
        1 if reading_correct else 0,
        0 if reading_correct else 1
    ))
    
    conn.commit()
    conn.close()
    
    return {
        "object": "review",
        "url": f"/v2/reviews/{assignment_id}",
        "data": {
            "created_at": datetime.utcnow().isoformat(),
            "assignment_id": assignment_id,
            "subject_id": subject_id,
            "starting_srs_stage": current_srs,
            "ending_srs_stage": new_srs
        }
    }

@router.post("/assignments/{assignment_id}/start")
async def start_assignment(assignment_id: int):
    """Start an assignment (begin lesson)"""
    conn = get_db_connection()
    cursor = conn.cursor()
    
    cursor.execute("""
        UPDATE assignments
        SET started_at = ?
        WHERE id = ?
    """, (datetime.utcnow().isoformat(), assignment_id))
    
    conn.commit()
    conn.close()
    
    return {"status": "success"}

@router.post("/lessons/{lesson_id}/start")
async def start_lesson(lesson_id: int):
    """Start a lesson"""
    # For now, this is similar to starting an assignment
    conn = get_db_connection()
    cursor = conn.cursor()
    
    cursor.execute("""
        UPDATE assignments
        SET started_at = ?
        WHERE id = ?
    """, (datetime.utcnow().isoformat(), lesson_id))
    
    conn.commit()
    conn.close()
    
    return {"status": "success"}

@router.get("/summary")
async def get_summary(request: Request):
    """Get summary (proxied)"""
    path = "/summary"
    return await proxy_request(request, path)

@router.get("/study_materials")
async def get_study_materials(request: Request):
    """Get study materials (proxied)"""
    path = "/study_materials"
    return await proxy_request(request, path)

@router.get("/level_progressions")
async def get_level_progressions(request: Request):
    """Get level progressions (proxied for now to see format)"""
    path = "/level_progressions"
    return await proxy_request(request, path)

@router.get("/voice_actors")
async def get_voice_actors(request: Request):
    """Get voice actors (proxied)"""
    path = "/voice_actors"
    return await proxy_request(request, path)

@router.get("/review_statistics")
async def get_review_statistics(request: Request):
    """Get review statistics (proxied and filtered by level 1)"""
    # Proxy the request to Wanikani
    path = "/review_statistics"
    response = await proxy_request(request, path)
    
    # Filter statistics to only show level 1
    if "data" in response:
        filtered_data = [
            stat for stat in response["data"]
            if stat["data"]["level"] == 1
        ]
        response["data"] = filtered_data
        response["total_count"] = len(filtered_data)
    
    return response
