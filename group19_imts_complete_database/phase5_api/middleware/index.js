const rateLimit = require("express-rate-limit");
const { validationResult } = require("express-validator");

const limiter = rateLimit({
  windowMs: parseInt(process.env.RATE_LIMIT_WINDOW_MS) || 900000,
  max: parseInt(process.env.RATE_LIMIT_MAX_REQUESTS) || 200,
  standardHeaders: true,
  legacyHeaders: false,
  message: { success: false, error: "Too many requests. Please retry after 15 minutes." },
});

const handleValidation = (req, res, next) => {
  const errors = validationResult(req);
  if (!errors.isEmpty()) {
    return res.status(422).json({
      success: false,
      error: "Validation failed",
      details: errors.array().map(e => ({ field: e.path, message: e.msg, value: e.value })),
    });
  }
  next();
};

const errorHandler = (err, req, res, next) => {
  if (process.env.NODE_ENV === "development") console.error("[ERROR]", err);
  else console.error("[ERROR]", err.message || err);

  if (err.errno || (err.code && err.code.startsWith("ER_"))) {
    const map = {
      ER_DUP_ENTRY: { status: 409, message: "Duplicate record." },
      ER_SIGNAL_EXCEPTION: { status: 422, message: err.sqlMessage || "Business rule violation." },
    };
    const m = map[err.code];
    if (m) return res.status(m.status).json({ success: false, error: m.message });
    return res.status(500).json({ success: false, error: "Database error.", detail: err.sqlMessage });
  }
  if (err.name === "MongoServerError") {
    return res.status(err.code === 121 ? 422 : 500).json({ success: false, error: "MongoDB error.", detail: err.message });
  }
  if (err.code && err.code.startsWith("Neo.")) {
    return res.status(500).json({ success: false, error: "Graph database error.", detail: err.message });
  }
  if (err.status) return res.status(err.status).json({ success: false, error: err.message });
  res.status(500).json({ success: false, error: "Internal server error.", detail: process.env.NODE_ENV === "development" ? err.message : undefined });
};

const notFound = (req, res) => {
  res.status(404).json({ success: false, error: "Route not found: " + req.method + " " + req.originalUrl });
};

module.exports = { limiter, handleValidation, errorHandler, notFound };
