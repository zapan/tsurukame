from fastapi import FastAPI
from contextlib import asynccontextmanager
from .database import init_db
from .custom_endpoints import router as custom_router

@asynccontextmanager
async def lifespan(app: FastAPI):
    # Initialize database on startup
    init_db()
    yield
    # Cleanup if needed

app = FastAPI(lifespan=lifespan)

# Include custom endpoints
app.include_router(custom_router, prefix="/v2")

@app.get("/health")
async def health_check():
    """Health check endpoint"""
    return {"status": "healthy"}

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
