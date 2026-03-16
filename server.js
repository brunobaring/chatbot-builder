import "dotenv/config";
import express from "express";
import { fileURLToPath } from "url";
import { dirname, join } from "path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const app = express();

app.use(express.json());
app.use(express.static(join(__dirname, "public")));

const FASTAPI_URL = process.env.FASTAPI_URL || "http://localhost:8000";

async function proxyToFastAPI(req, res) {
  try {
    const isGet = req.method === "GET";
    const response = await fetch(`${FASTAPI_URL}${req.path}`, {
      method: req.method,
      headers: { "Content-Type": "application/json" },
      ...(isGet ? {} : { body: JSON.stringify(req.body) }),
    });
    const data = await response.json();
    res.status(response.status).json(data);
  } catch (err) {
    console.error(err);
    res.status(502).json({ error: "Erro ao conectar com a API." });
  }
}

app.post("/api/config", proxyToFastAPI);
app.post("/api/messages", proxyToFastAPI);
app.post("/api/whatsapp/connect", proxyToFastAPI);
app.post("/api/whatsapp/webhook", proxyToFastAPI);
app.get("/api/whatsapp/qr/:instance", (req, res) => {
  proxyToFastAPI({ ...req, path: `/api/whatsapp/qr/${req.params.instance}` }, res);
});
app.get("/api/whatsapp/status/:instance", (req, res) => {
  proxyToFastAPI({ ...req, path: `/api/whatsapp/status/${req.params.instance}` }, res);
});

const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
  console.log(`Servidor rodando em http://localhost:${PORT}`);
});
