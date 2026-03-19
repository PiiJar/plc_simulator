FROM joyja/codesys-control:version-4.12.00

# Copy entrypoint wrapper — keeps container alive while
# codesyscontrol.bin can be started/stopped independently
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
