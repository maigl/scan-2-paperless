FROM ubuntu:24.04

RUN apt update && apt install -y imagemagick libsane1
RUN rm -rf /var/lib/apt/lists/*

COPY scan.sh /usr/local/bin/scan.sh
RUN chmod +x /usr/local/bin/scan.sh

ENTRYPOINT ["/usr/local/bin/scan.sh"]