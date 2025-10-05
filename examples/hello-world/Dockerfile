FROM python:3.11-slim

# Create working directory
WORKDIR /app

# Create a minimal hello world script
RUN echo 'print("Hello, world!")' > hello.py

# Set default command to run the script
ENTRYPOINT ["python", "hello.py"]