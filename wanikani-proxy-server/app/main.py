from fastapi import FastAPI, Request, HTTPException
from fastapi.responses import HTMLResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from contextlib import asynccontextmanager
import httpx
from .database import init_db, get_config, save_config
from .proxy import proxy_request
from .custom_endpoints import router as custom_router

@asynccontextmanager
async def lifespan(app: FastAPI):
    # Initialize database on startup
    init_db()
    yield
    # Cleanup if needed

app = FastAPI(lifespan=lifespan)

# Mount static files and templates
app.mount("/static", StaticFiles(directory="app/static"), name="static")
templates = Jinja2Templates(directory="app/templates")

# Include custom endpoints
app.include_router(custom_router, prefix="/v2")

@app.get("/config", response_class=HTMLResponse)
async def config_page(request: Request):
    """Configuration page for API key"""
    api_key = get_config("wanikani_api_key")
    return templates.TemplateResponse("config.html", {
        "request": request,
        "api_key_configured": bool(api_key)
    })

@app.post("/config")
async def save_api_key(request: Request):
    """Save API key from configuration page"""
    data = await request.json()
    api_key = data.get("api_key")
    
    if not api_key:
        raise HTTPException(status_code=400, detail="API key is required")
    
    save_config("wanikani_api_key", api_key)
    return {"status": "success", "message": "API key saved successfully"}

@app.get("/health")
async def health_check():
    """Health check endpoint"""
    return {"status": "healthy"}

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
