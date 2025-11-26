FROM python:3.9-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install -r requirements.txt

COPY . .

# Flask по умолчанию на 5000 порту
CMD ["gunicorn", "-b", "0.0.0.0:5000", "app:app"]