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
async def get_user():
    """Get user information (custom)"""
    user_info = get_user_info()
    
    return {
        "id": "local-user",
        "username": user_info.get("username", "Local User"),
        "level": user_info.get("level", 1),
        "max_level": 60,
        "profile_url": None,
        "started_at": user_info.get("started_at"),
        "current_vacation_started_at": None,
        "subscription": {
            "active": True,
            "max_level": 60,
            "period_ends_at": None
        },
        "preferences": {
            "lessons_autoplay_audio": True,
            "lessons_batch_size": 5,
            "lessons_presentation_order": "level",
            "reviews_autoplay_audio": True,
            "reviews_display_srs_indicator": True
        }
    }

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
    """Get assignments (custom - based on local progress)"""
    conn = get_db_connection()
    cursor = conn.cursor()
    
    # Get all assignments
    cursor.execute("""
        SELECT * FROM assignments
        WHERE passed_at IS NULL
        ORDER BY available_at ASC
    """)
    
    assignments = []
    for row in cursor.fetchall():
        assignments.append({
            "id": row["id"],
            "object": "assignment",
            "url": f"/v2/assignments/{row['id']}",
            "data": {
                "created_at": row["created_at"],
                "subject_id": row["subject_id"],
                "subject_type": row["subject_type"],
                "level": row["level"],
                "srs_stage": row["srs_stage"],
                "available_at": row["available_at"],
                "started_at": row["started_at"],
                "passed_at": row["passed_at"]
            }
        })
    
    conn.close()
    
    return {
        "object": "collection",
        "url": "/v2/assignments",
        "pages": {
            "per_page": 500,
            "next_url": None,
            "previous_url": None
        },
        "total_count": len(assignments),
        "data": assignments
    }

@router.get("/reviews")
async def get_reviews(request: Request):
    """Get reviews (custom - based on local SRS)"""
    conn = get_db_connection()
    cursor = conn.cursor()
    
    current_time = datetime.utcnow()
    
    # Get assignments that are due for review
    cursor.execute("""
        SELECT a.*, rs.meaning_correct, rs.meaning_incorrect, 
               rs.reading_correct, rs.reading_incorrect
        FROM assignments a
        LEFT JOIN review_statistics rs ON a.subject_id = rs.subject_id
        WHERE a.passed_at IS NULL 
        AND (a.available_at IS NULL OR datetime(a.available_at) <= ?)
        ORDER BY a.available_at ASC
    """, (current_time.isoformat(),))
    
    reviews = []
    for row in cursor.fetchall():
        reviews.append({
            "id": row["id"],
            "object": "review",
            "url": f"/v2/reviews/{row['id']}",
            "data": {
                "created_at": row["created_at"],
                "assignment_id": row["id"],
                "subject_id": row["subject_id"],
                "subject_type": row["subject_type"],
                "starting_srs_stage": row["srs_stage"],
                "ending_srs_stage": row["srs_stage"]
            }
        })
    
    conn.close()
    
    return {
        "object": "collection",
        "url": "/v2/reviews",
        "pages": {
            "per_page": 500,
            "next_url": None,
            "previous_url": None
        },
        "total_count": len(reviews),
        "data": reviews
    }

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
    """Get summary (proxied with custom review counts)"""
    # Get review count from local database
    conn = get_db_connection()
    cursor = conn.cursor()
    
    current_time = datetime.utcnow()
    cursor.execute("""
        SELECT COUNT(*) as count
        FROM assignments
        WHERE passed_at IS NULL 
        AND (available_at IS NULL OR datetime(available_at) <= ?)
    """, (current_time.isoformat(),))
    
    review_count = cursor.fetchone()["count"]
    conn.close()
    
    # Proxy the summary request
    path = "/summary"
    response = await proxy_request(request, path)
    
    # Override review counts
    if "data" in response:
        response["data"]["reviews"] = review_count
    
    return response
