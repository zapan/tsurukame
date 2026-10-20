import httpx
from fastapi import Request, HTTPException

WANIKANI_API_BASE = "https://api.wanikani.com/v2"

async def proxy_request(request: Request, path: str):
    """Proxy request to Wanikani API using the token from the request header"""
    # Extract API key from Authorization header
    auth_header = request.headers.get("Authorization")
    if not auth_header or not auth_header.startswith("Bearer "):
        raise HTTPException(
            status_code=401,
            detail="Authorization header missing or invalid"
        )
    
    api_key = auth_header.replace("Bearer ", "")
    
    # Build the full URL
    url = f"{WANIKANI_API_BASE}{path}"
    
    # Get query parameters
    query_params = dict(request.query_params)
    
    # Get request body if present
    body = None
    if request.method in ["POST", "PUT", "PATCH"]:
        body = await request.json()
    
    # Make the request to Wanikani
    async with httpx.AsyncClient() as client:
        headers = {
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        }
        
        try:
            if request.method == "GET":
                response = await client.get(url, headers=headers, params=query_params)
            elif request.method == "POST":
                response = await client.post(url, headers=headers, json=body, params=query_params)
            elif request.method == "PUT":
                response = await client.put(url, headers=headers, json=body, params=query_params)
            elif request.method == "PATCH":
                response = await client.patch(url, headers=headers, json=body, params=query_params)
            elif request.method == "DELETE":
                response = await client.delete(url, headers=headers, params=query_params)
            else:
                raise HTTPException(status_code=405, detail="Method not allowed")
            
            return response.json()
            
        except httpx.HTTPError as e:
            raise HTTPException(status_code=502, detail=f"Error proxying to Wanikani API: {str(e)}")
