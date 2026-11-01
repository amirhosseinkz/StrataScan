"use strict";

const http = require("node:http");
const { URL } = require("node:url");

const API_PREFIX = "/v1";
const MAX_BODY_BYTES = 1_048_576;
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const CHECKSUM_PATTERN = /^[a-f0-9]{4,128}$/i;
const ISO_DATE_TIME_PATTERN = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})$/;
const UPLOAD_FIELDS = new Set([
  "idempotencyKey",
  "localScanID",
  "remoteScanID",
  "displayName",
  "checksumSHA256",
  "expectedRevision",
  "updatedAt"
]);

class RequestError extends Error {
  constructor(statusCode, code, message) {
    super(message);
    this.statusCode = statusCode;
    this.code = code;
  }
}

function createServer() {
  const scans = new Map();
  const idempotencyRecords = new Map();

  return http.createServer((request, response) => {
    void handleRequest(request, response, scans, idempotencyRecords).catch((error) => {
      if (response.writableEnded) {
        return;
      }
      if (error instanceof RequestError) {
        sendError(response, error.statusCode, error.code, error.message);
        return;
      }
      sendError(response, 500, "internal_error", "The mock server could not process the request.");
    });
  });
}

async function handleRequest(request, response, scans, idempotencyRecords) {
  const requestURL = new URL(request.url || "/", "http://127.0.0.1");
  const pathname = requestURL.pathname;

  if (request.method === "GET" && pathname === `${API_PREFIX}/health`) {
    sendJSON(response, 200, { status: "ok", apiVersion: "v1" });
    return;
  }

  if (request.method === "POST" && pathname === `${API_PREFIX}/scans`) {
    const payload = await readJSON(request);
    const validation = validateUpload(payload);
    if (validation) {
      sendError(response, 400, "invalid_request", validation);
      return;
    }

    const fingerprint = requestFingerprint(payload);
    const previous = idempotencyRecords.get(payload.idempotencyKey);
    if (previous) {
      if (previous.fingerprint !== fingerprint) {
        sendError(response, 409, "idempotency_mismatch", "The idempotency key was reused for a different request.");
        return;
      }
      sendJSON(response, previous.statusCode, previous.payload);
      return;
    }

    const remoteScanID = payload.remoteScanID || `scan-${payload.localScanID.toLowerCase()}`;
    const existing = scans.get(remoteScanID);
    if (existing && payload.expectedRevision !== existing.revision) {
      sendError(
        response,
        409,
        "revision_conflict",
        "The remote scan has changed.",
        existing
      );
      return;
    }

    const scan = {
      id: remoteScanID,
      localScanID: payload.localScanID,
      displayName: payload.displayName,
      checksumSHA256: payload.checksumSHA256,
      revision: existing ? nextRevision(existing.revision) : "1",
      updatedAt: payload.updatedAt
    };
    const result = { scan, wasCreated: !existing };
    const statusCode = existing ? 200 : 201;

    scans.set(remoteScanID, scan);
    idempotencyRecords.set(payload.idempotencyKey, { fingerprint, statusCode, payload: result });
    sendJSON(response, statusCode, result);
    return;
  }

  const scanID = scanIDFromPath(pathname);
  if (request.method === "GET" && scanID) {
    const scan = scans.get(scanID);
    if (!scan) {
      sendError(response, 404, "not_found", "No remote scan exists for this identifier.");
      return;
    }
    sendJSON(response, 200, scan);
    return;
  }

  sendError(response, 404, "not_found", "No route matches this request.");
}

function readJSON(request) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let bodyBytes = 0;
    let tooLarge = false;

    request.on("data", (chunk) => {
      if (tooLarge) {
        return;
      }
      bodyBytes += chunk.length;
      if (bodyBytes > MAX_BODY_BYTES) {
        tooLarge = true;
        reject(new RequestError(413, "payload_too_large", "Request payload exceeds the contract limit."));
        request.resume();
        return;
      }
      chunks.push(chunk);
    });
    request.on("end", () => {
      if (tooLarge) {
        return;
      }
      if (chunks.length === 0) {
        reject(new RequestError(400, "invalid_request", "A JSON request body is required."));
        return;
      }
      try {
        resolve(JSON.parse(Buffer.concat(chunks).toString("utf8")));
      } catch {
        reject(new RequestError(400, "invalid_json", "The request body must be valid JSON."));
      }
    });
    request.on("error", () => {
      if (!tooLarge) {
        reject(new RequestError(400, "invalid_request", "The request body could not be read."));
      }
    });
  });
}

function validateUpload(payload) {
  if (!payload || Array.isArray(payload) || typeof payload !== "object") {
    return "The request body must be an object.";
  }
  if (Object.keys(payload).some((key) => !UPLOAD_FIELDS.has(key))) {
    return "The request body contains an unsupported property.";
  }
  if (!UUID_PATTERN.test(payload.idempotencyKey || "")) {
    return "idempotencyKey must be a UUID.";
  }
  if (!UUID_PATTERN.test(payload.localScanID || "")) {
    return "localScanID must be a UUID.";
  }
  if (!nonEmptyString(payload.displayName) || payload.displayName.length > 200) {
    return "displayName must contain between 1 and 200 characters.";
  }
  if (!CHECKSUM_PATTERN.test(payload.checksumSHA256 || "")) {
    return "checksumSHA256 must contain hexadecimal characters.";
  }
  if (!isDateTime(payload.updatedAt)) {
    return "updatedAt must be an ISO-8601 date-time.";
  }
  if (payload.remoteScanID !== undefined && !nonEmptyString(payload.remoteScanID)) {
    return "remoteScanID must be a non-empty string when supplied.";
  }
  if (payload.expectedRevision !== undefined && !nonEmptyString(payload.expectedRevision)) {
    return "expectedRevision must be a non-empty string when supplied.";
  }
  return null;
}

function requestFingerprint(payload) {
  return JSON.stringify({
    idempotencyKey: payload.idempotencyKey,
    localScanID: payload.localScanID,
    remoteScanID: payload.remoteScanID || null,
    displayName: payload.displayName,
    checksumSHA256: payload.checksumSHA256,
    expectedRevision: payload.expectedRevision || null,
    updatedAt: payload.updatedAt
  });
}

function nextRevision(revision) {
  const numericRevision = Number.parseInt(revision, 10);
  return Number.isSafeInteger(numericRevision) && numericRevision >= 0
    ? String(numericRevision + 1)
    : "1";
}

function scanIDFromPath(pathname) {
  const prefix = `${API_PREFIX}/scans/`;
  if (!pathname.startsWith(prefix)) {
    return null;
  }
  const encodedID = pathname.slice(prefix.length);
  if (!encodedID || encodedID.includes("/")) {
    return null;
  }
  try {
    return decodeURIComponent(encodedID);
  } catch {
    return null;
  }
}

function nonEmptyString(value) {
  return typeof value === "string" && value.trim().length > 0;
}

function isDateTime(value) {
  return typeof value === "string" && ISO_DATE_TIME_PATTERN.test(value) && !Number.isNaN(Date.parse(value));
}

function sendError(response, statusCode, code, message, currentScan) {
  const body = { code, message };
  if (currentScan) {
    body.currentScan = currentScan;
  }
  sendJSON(response, statusCode, body);
}

function sendJSON(response, statusCode, payload) {
  const body = JSON.stringify(payload);
  response.writeHead(statusCode, {
    "Cache-Control": "no-store",
    "Content-Length": Buffer.byteLength(body),
    "Content-Type": "application/json; charset=utf-8"
  });
  response.end(body);
}

function portFromEnvironment(value) {
  const port = Number(value || 8080);
  return Number.isInteger(port) && port > 0 && port <= 65535 ? port : 8080;
}

if (require.main === module) {
  const port = portFromEnvironment(process.env.PORT);
  const host = process.env.HOST || "127.0.0.1";
  createServer().listen(port, host, () => {
    console.log(`StrataScan mock server listening at http://${host}:${port}${API_PREFIX}`);
  });
}

module.exports = { createServer };
