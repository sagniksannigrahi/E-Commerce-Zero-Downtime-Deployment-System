"""Unit tests for the ShopFlow Flask application."""

import importlib

import pytest

import app as shopflow


@pytest.fixture
def client():
    shopflow.app.config.update(TESTING=True)
    with shopflow.app.test_client() as client:
        yield client


# ---------------------------------------------------------------- homepage
def test_homepage_loads(client):
    response = client.get("/")
    assert response.status_code == 200
    html = response.get_data(as_text=True)
    assert "ShopFlow" in html
    assert "Deployment monitor" in html


def test_homepage_shows_every_product(client):
    html = client.get("/").get_data(as_text=True)
    for product in shopflow.PRODUCTS:
        assert product["name"] in html


def test_homepage_shows_deployment_version(client):
    html = client.get("/").get_data(as_text=True)
    assert f"v{shopflow.APP_VERSION}" in html


# ---------------------------------------------------------------- products
def test_product_listing(client):
    response = client.get("/api/products")
    assert response.status_code == 200
    data = response.get_json()
    assert data["count"] == len(shopflow.PRODUCTS) == len(data["products"])
    for product in data["products"]:
        assert {"id", "name", "price", "category"} <= product.keys()
        assert product["price"] > 0


def test_single_product_and_missing_product(client):
    assert client.get("/api/products/1").get_json()["id"] == 1
    assert client.get("/api/products/999").status_code == 404


# ---------------------------------------------------------------- cart
def test_cart_starts_empty(client):
    data = client.get("/api/cart").get_json()
    assert data["items"] == []
    assert data["total"] == 0


def test_add_to_cart_and_totals(client):
    client.post("/api/cart/add", json={"product_id": 1, "quantity": 2})
    data = client.post("/api/cart/add", json={"product_id": 5, "quantity": 1}).get_json()

    expected_subtotal = 2 * 2499.0 + 1799.0
    assert data["item_count"] == 3
    assert data["subtotal"] == expected_subtotal
    assert data["shipping"] == 0.0  # free shipping above 5000
    assert data["total"] == expected_subtotal


def test_small_orders_pay_shipping(client):
    data = client.post("/api/cart/add", json={"product_id": 8}).get_json()
    assert data["shipping"] == 99.0
    assert data["total"] == 1199.0 + 99.0


def test_cart_persists_between_requests(client):
    client.post("/api/cart/add", json={"product_id": 3})
    assert client.get("/api/cart").get_json()["item_count"] == 1


def test_remove_and_clear_cart(client):
    client.post("/api/cart/add", json={"product_id": 1})
    client.post("/api/cart/add", json={"product_id": 2})
    data = client.post("/api/cart/remove", json={"product_id": 1}).get_json()
    assert [i["product_id"] for i in data["items"]] == [2]
    assert client.post("/api/cart/clear").get_json()["item_count"] == 0


@pytest.mark.parametrize("payload", [
    {"product_id": 999},
    {"product_id": "abc"},
    {"product_id": 1, "quantity": 0},
    {"product_id": 1, "quantity": 50},
    {},
])
def test_invalid_cart_requests_are_rejected(client, payload):
    response = client.post("/api/cart/add", json=payload)
    assert response.status_code == 400
    assert "error" in response.get_json()


def test_checkout_confirms_order_and_empties_cart(client):
    client.post("/api/cart/add", json={"product_id": 4})
    response = client.post("/api/checkout")
    assert response.status_code == 201
    order = response.get_json()
    assert order["status"] == "confirmed"
    assert order["order_id"].startswith("SF-")
    assert order["total"] == 7499.0
    assert client.get("/api/cart").get_json()["item_count"] == 0


def test_checkout_with_empty_cart_fails(client):
    assert client.post("/api/checkout").status_code == 400


# ---------------------------------------------------------------- health & status
def test_health_endpoint(client):
    response = client.get("/health")
    assert response.status_code == 200
    data = response.get_json()
    assert data["status"] == "healthy"
    assert {"version", "color", "build", "release"} <= data.keys()


def test_status_endpoint(client):
    response = client.get("/api/status")
    assert response.status_code == 200
    data = response.get_json()
    assert data["app"] == "ShopFlow"
    assert data["status"] == "running"
    assert data["product_count"] == len(shopflow.PRODUCTS)
    assert data["uptime_seconds"] >= 0


def test_deployment_headers(client):
    response = client.get("/health")
    assert response.headers["X-ShopFlow-Version"] == shopflow.APP_VERSION
    assert response.headers["X-ShopFlow-Color"] == shopflow.APP_COLOR


def test_environment_variables_configure_the_release(monkeypatch):
    monkeypatch.setenv("APP_VERSION", "9.9.9")
    monkeypatch.setenv("APP_COLOR", "green")
    monkeypatch.setenv("RELEASE_ID", "abc1234-20260101")
    module = importlib.reload(shopflow)
    try:
        data = module.app.test_client().get("/health").get_json()
        assert data == {"status": "healthy", "version": "9.9.9", "color": "green",
                        "build": module.BUILD_SHA, "release": "abc1234-20260101"}
    finally:
        monkeypatch.undo()
        importlib.reload(shopflow)


def test_simulated_failure_makes_health_check_fail(monkeypatch):
    """A broken release must report 503 so deploy.sh refuses to switch to it."""
    monkeypatch.setenv("SIMULATE_UNHEALTHY", "true")
    module = importlib.reload(shopflow)
    try:
        response = module.app.test_client().get("/health")
        assert response.status_code == 503
        assert response.get_json()["status"] == "unhealthy"
    finally:
        monkeypatch.undo()
        importlib.reload(shopflow)
