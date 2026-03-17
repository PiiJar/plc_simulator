FROM node:20-alpine

WORKDIR /app

COPY package.json ./
RUN npm install --production

COPY index.js plc_adapter.js opcua_adapter.js opcua_nodes.js \
     db.js event_consumer.js file_routes.js legacy_stubs.js \
     production_dispatcher.js ./

EXPOSE 3001

CMD ["node", "index.js"]
