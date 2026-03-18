FROM node:20-alpine

WORKDIR /app

COPY package.json ./
RUN npm install --production

COPY index.js plc_adapter.js opcua_adapter.js opcua_nodes.js \
     db.js event_consumer.js file_routes.js legacy_stubs.js \
     production_dispatcher.js ./

EXPOSE 3001

# CODESYS OPC UA uses RSA PKCS#1 v1.5 which Node >= 20 rejects by default
# --security-revert must be a direct CLI arg (not allowed in NODE_OPTIONS)
CMD ["node", "--security-revert=CVE-2023-46809", "index.js"]
