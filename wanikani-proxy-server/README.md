# Wanikani Proxy Server

A local proxy server that emulates the Wanikani API, allowing you to reset your progress to level 1 without affecting your actual Wanikani account.

## Features

- **Proxy Content**: Forwards content requests (radicals, kanji, vocabulary) to the official Wanikani API
- **Custom Progress**: Manages your learning progress independently (SRS levels, assignments, reviews)
- **Level 1 Reset**: Start fresh from level 1 while keeping your original Wanikani progress intact
- **Local Database**: Uses SQLite to store your personal progress
- **Configuration UI**: Simple web interface to set up your Wanikani API key

## Setup

### Prerequisites

- Python 3.10 or higher
- pip (Python package manager)

### Installation

1. Navigate to the project directory:
```bash
cd wanikani-proxy-server
```

2. Install dependencies:
```bash
pip install -r requirements.txt
```

3. Start the server:
```bash
python -m app.main
```

Or using uvicorn directly:
```bash
uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload
```

### Configuration

1. Open your browser and go to: `http://localhost:8000/config`
2. Enter your Wanikani API key (get it from https://www.wanikani.com/settings/personal_access_tokens)
3. Click "Save Configuration"

### Configure Tsurukame

1. Open Tsurukame app
2. Go to Settings → Developer options
3. Change "API base URL" to: `http://localhost:8000/v2`
4. The app will now use your local proxy server

## How It Works

### Proxied Endpoints (Content)
- `GET /subjects` - Retrieves radicals, kanji, vocabulary (filtered by your current level)
- `GET /subjects/:id` - Retrieves specific subject details
- `GET /summary` - General summary information

### Custom Endpoints (Progress)
- `GET /user` - Returns your custom user profile (level 1, reset stats)
- `GET /assignments` - Returns assignments based on your local progress
- `GET /reviews` - Returns reviews due based on your local SRS
- `POST /reviews` - Updates your local SRS progress
- `POST /assignments/:id/start` - Marks an assignment as started
- `POST /lessons/:id/start` - Marks a lesson as started

## SRS System

The proxy implements Wanikani's SRS system with the following stages:

1. **Initiate** (0) - Immediately available
2. **Apprentice I** (1) - 2 hours
3. **Apprentice II** (2) - 4 hours
4. **Apprentice III** (3) - 8 hours
5. **Apprentice IV** (4) - 24 hours
6. **Guru I** (5) - 48 hours
7. **Guru II** (6) - 7 days
8. **Master** (7) - 30 days
9. **Enlightened** (8) - 180 days
10. **Burned** (9) - No more reviews

## Database

The server uses SQLite (`wanikani_proxy.db`) with the following tables:

- `config` - Stores encrypted API keys and other settings
- `user_info` - Stores your local user profile
- `assignments` - Tracks which items are assigned for learning/review
- `review_statistics` - Stores SRS statistics for each item
- `subject_progress` - Tracks progress for each subject

## Security

- API keys are encrypted using Fernet symmetric encryption before storage
- The server only runs locally (localhost) by default
- No data is sent to external servers except the official Wanikani API for content

## Troubleshooting

### Server won't start
- Make sure Python 3.10+ is installed: `python --version`
- Check if port 8000 is already in use
- Ensure all dependencies are installed

### API key errors
- Verify your API key is valid in Wanikani settings
- Make sure you've saved the API key in the configuration page
- Check the server logs for error messages

### Tsurukame not connecting
- Ensure the proxy server is running
- Verify the API base URL is set to `http://localhost:8000/v2`
- Check that your API key is configured

## Development

### Project Structure

```
wanikani-proxy-server/
├── app/
│   ├── __init__.py
│   ├── main.py              # FastAPI application entry point
│   ├── database.py          # Database operations
│   ├── proxy.py             # Proxy logic for Wanikani API
│   ├── custom_endpoints.py  # Custom progress endpoints
│   ├── templates/
│   │   └── config.html      # Configuration UI
│   └── static/              # Static files (if needed)
├── requirements.txt
├── README.md
└── wanikani_proxy.db        # SQLite database (created on first run)
```

## Future Enhancements

- [ ] Import subjects from Wanikani to populate local assignments
- [ ] Implement proper level unlocking logic
- [ ] Add web dashboard to view progress
- [ ] Support for multiple users
- [ ] Export/import progress data
- [ ] Advanced SRS customization
