"""ShopFlow - a small e-commerce demo app used to showcase zero-downtime
Blue-Green deployments.

The shop itself is intentionally simple (products live in memory, the cart
lives in a signed session cookie). The interesting parts for DevOps are:

  * GET /health      -> used by deploy.sh, Docker and GitHub Actions
  * GET /api/status  -> shows which environment (blue/green) and version
                        is currently serving traffic
"""

import os
import platform
import socket
import time
import uuid
from datetime import datetime, timezone

from flask import Flask, jsonify, render_template, request, session

# ---------------------------------------------------------------------------
# Configuration (all injected through environment variables)
# ---------------------------------------------------------------------------
APP_NAME = "ShopFlow"
BASE_DIR = os.path.dirname(os.path.abspath(__file__))


def _version_from_file():
    try:
        with open(os.path.join(BASE_DIR, "VERSION"), encoding="utf-8") as fh:
            return fh.read().strip() or "dev"
    except OSError:
        return "dev"


APP_VERSION = os.environ.get("APP_VERSION") or _version_from_file()
APP_COLOR = os.environ.get("APP_COLOR", "local")  # blue | green | local
BUILD_SHA = os.environ.get("BUILD_SHA", "local")
RELEASE_ID = os.environ.get("RELEASE_ID", "local")
# Used only to demonstrate a broken release: the health check fails, so the
# deployment script refuses to send traffic to this version.
SIMULATE_UNHEALTHY = os.environ.get("SIMULATE_UNHEALTHY", "false").lower() == "true"
STARTED_AT = time.time()

app = Flask(__name__)
# The same SECRET_KEY is given to blue and green, so a shopper's cart
# survives a deployment (the cookie stays valid on the new version).
app.secret_key = os.environ.get("SECRET_KEY", "dev-only-secret-change-me")
app.config.update(SESSION_COOKIE_HTTPONLY=True, SESSION_COOKIE_SAMESITE="Lax")

# ---------------------------------------------------------------------------
# Product catalogue (in memory - no database needed for this demo)
# ---------------------------------------------------------------------------
PRODUCTS = [
    {"id": 1, "name": "Wireless Headphones", "price": 2499.0, "category": "Audio",
     "icon": "🎧", "rating": 4.6, "color": "#6366f1"},
    {"id": 2, "name": "Smart Watch", "price": 3999.0, "category": "Wearables",
     "icon": "⌚", "rating": 4.4, "color": "#0ea5e9"},
    {"id": 3, "name": "Mechanical Keyboard", "price": 3299.0, "category": "Accessories",
     "icon": "⌨️", "rating": 4.8, "color": "#f59e0b"},
    {"id": 4, "name": "4K Action Camera", "price": 7499.0, "category": "Cameras",
     "icon": "📷", "rating": 4.3, "color": "#ef4444"},
    {"id": 5, "name": "Bluetooth Speaker", "price": 1799.0, "category": "Audio",
     "icon": "🔊", "rating": 4.5, "color": "#10b981"},
    {"id": 6, "name": "Gaming Mouse", "price": 1299.0, "category": "Accessories",
     "icon": "🖱️", "rating": 4.7, "color": "#8b5cf6"},
    {"id": 7, "name": "Laptop Backpack", "price": 1599.0, "category": "Bags",
     "icon": "🎒", "rating": 4.2, "color": "#14b8a6"},
    {"id": 8, "name": "Power Bank 20000mAh", "price": 1199.0, "category": "Accessories",
     "icon": "🔋", "rating": 4.5, "color": "#ec4899"},
]
PRODUCTS_BY_ID = {p["id"]: p for p in PRODUCTS}
MAX_QTY_PER_ITEM = 10


def deployment_info():
    return {
        "version": APP_VERSION,
        "color": APP_COLOR,
        "build": BUILD_SHA,
        "release": RELEASE_ID,
    }


# ---------------------------------------------------------------------------
# Cart helpers (cart = {"<product_id>": quantity} stored in the session)
# ---------------------------------------------------------------------------
def _get_cart():
    return session.get("cart", {})


def _save_cart(cart):
    session["cart"] = cart
    session.modified = True


def cart_summary(cart):
    items = []
    for pid, qty in cart.items():
        product = PRODUCTS_BY_ID.get(int(pid))
        if product is None:
            continue
        items.append({
            "product_id": product["id"],
            "name": product["name"],
            "icon": product["icon"],
            "price": product["price"],
            "quantity": qty,
            "line_total": round(product["price"] * qty, 2),
        })
    subtotal = round(sum(i["line_total"] for i in items), 2)
    shipping = 0.0 if subtotal == 0 or subtotal >= 5000 else 99.0
    return {
        "items": items,
        "item_count": sum(i["quantity"] for i in items),
        "subtotal": subtotal,
        "shipping": shipping,
        "total": round(subtotal + shipping, 2),
    }


def _read_product_and_qty():
    data = request.get_json(silent=True) or {}
    try:
        product_id = int(data.get("product_id"))
        quantity = int(data.get("quantity", 1))
    except (TypeError, ValueError):
        return None, None, "product_id and quantity must be integers"
    if product_id not in PRODUCTS_BY_ID:
        return None, None, f"product {product_id} does not exist"
    if quantity < 1 or quantity > MAX_QTY_PER_ITEM:
        return None, None, f"quantity must be between 1 and {MAX_QTY_PER_ITEM}"
    return product_id, quantity, None


# ---------------------------------------------------------------------------
# Pages
# ---------------------------------------------------------------------------
@app.route("/")
def index():
    return render_template("index.html", products=PRODUCTS, deploy=deployment_info(),
                           app_name=APP_NAME)


# ---------------------------------------------------------------------------
# Operational endpoints
# ---------------------------------------------------------------------------
@app.route("/health")
def health():
    if SIMULATE_UNHEALTHY:
        return jsonify(status="unhealthy", reason="simulated failure", **deployment_info()), 503
    return jsonify(status="healthy", **deployment_info()), 200


@app.route("/api/status")
def status():
    return jsonify(
        app=APP_NAME,
        status="unhealthy" if SIMULATE_UNHEALTHY else "running",
        hostname=socket.gethostname(),
        python=platform.python_version(),
        started_at=datetime.fromtimestamp(STARTED_AT, timezone.utc).isoformat(),
        uptime_seconds=int(time.time() - STARTED_AT),
        server_time=datetime.now(timezone.utc).isoformat(),
        product_count=len(PRODUCTS),
        **deployment_info(),
    )


# ---------------------------------------------------------------------------
# Shop API
# ---------------------------------------------------------------------------
@app.route("/api/products")
def list_products():
    return jsonify(products=PRODUCTS, count=len(PRODUCTS))


@app.route("/api/products/<int:product_id>")
def get_product(product_id):
    product = PRODUCTS_BY_ID.get(product_id)
    if product is None:
        return jsonify(error="product not found"), 404
    return jsonify(product)


@app.route("/api/cart", methods=["GET"])
def get_cart():
    return jsonify(cart_summary(_get_cart()))


@app.route("/api/cart/add", methods=["POST"])
def add_to_cart():
    product_id, quantity, error = _read_product_and_qty()
    if error:
        return jsonify(error=error), 400
    cart = _get_cart()
    key = str(product_id)
    cart[key] = min(cart.get(key, 0) + quantity, MAX_QTY_PER_ITEM)
    _save_cart(cart)
    return jsonify(cart_summary(cart))


@app.route("/api/cart/remove", methods=["POST"])
def remove_from_cart():
    data = request.get_json(silent=True) or {}
    cart = _get_cart()
    cart.pop(str(data.get("product_id")), None)
    _save_cart(cart)
    return jsonify(cart_summary(cart))


@app.route("/api/cart/clear", methods=["POST"])
def clear_cart():
    _save_cart({})
    return jsonify(cart_summary({}))


@app.route("/api/checkout", methods=["POST"])
def checkout():
    summary = cart_summary(_get_cart())
    if summary["item_count"] == 0:
        return jsonify(error="cart is empty"), 400
    order = {
        "order_id": "SF-" + uuid.uuid4().hex[:8].upper(),
        "status": "confirmed",
        "placed_at": datetime.now(timezone.utc).isoformat(),
        "served_by": APP_COLOR,
        "version": APP_VERSION,
        **summary,
    }
    _save_cart({})
    return jsonify(order), 201


@app.after_request
def add_deployment_headers(response):
    # Handy for demos: `curl -I` shows which environment answered.
    response.headers["X-ShopFlow-Version"] = APP_VERSION
    response.headers["X-ShopFlow-Color"] = APP_COLOR
    return response


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", 5000)), debug=False)
