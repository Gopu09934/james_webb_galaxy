FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y \
        ffmpeg \
        curl \
        ca-certificates \
        python3 \
        python3-pip && \
    pip3 install --break-system-packages Pillow && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY start.sh .
COPY overlay.png .
COPY font.ttf .

RUN chmod +x start.sh

CMD ["./start.sh"]
