# Vega Module
# Common development recipes

# Default recipe: show help
default:
    @just --list

# Run the node against real hardware
run:
    python src/vega_rest_node.py

# Alias for `run`. The fake interface is not implemented yet, so there is no
# hardware-free way to start the node.
run-real: run

# Run tests
test:
    PYTHONPATH=src:. pytest tests/

# Run tests with coverage
coverage:
    PYTHONPATH=src:. pytest tests/ --cov=src --cov-report=html

# Lint code
lint:
    ruff check .

# Format code
format:
    ruff format .

# Install in development mode
build:
    pip install -e ".[dev]"

# Build Docker image
docker-build:
    docker build -t vega-module .

# Run in Docker
docker-run:
    docker run -p 2000:2000 vega-module
