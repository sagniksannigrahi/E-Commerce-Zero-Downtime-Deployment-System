// ShopFlow front-end: cart handling + live deployment monitor.
(function () {
  "use strict";

  const $ = (id) => document.getElementById(id);
  const rupees = (n) => "₹" + Number(n).toLocaleString("en-IN", { maximumFractionDigits: 0 });

  // ------------------------------------------------------------------
  // Helpers
  // ------------------------------------------------------------------
  async function api(path, options = {}) {
    const res = await fetch(path, {
      headers: { "Content-Type": "application/json" },
      credentials: "same-origin",
      cache: "no-store",
      ...options,
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(data.error || `Request failed (${res.status})`);
    return data;
  }

  let toastTimer;
  function toast(message) {
    const el = $("toast");
    el.textContent = message;
    el.classList.add("show");
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => el.classList.remove("show"), 2200);
  }

  // ------------------------------------------------------------------
  // Cart
  // ------------------------------------------------------------------
  function renderCart(cart) {
    $("cartCount").textContent = cart.item_count;
    $("kpiTotal").textContent = rupees(cart.total);
    $("kpiItems").textContent = `${cart.item_count} item${cart.item_count === 1 ? "" : "s"}`;
    $("cartSubtotal").textContent = rupees(cart.subtotal);
    $("cartShipping").textContent = cart.shipping ? rupees(cart.shipping) : "Free";
    $("cartTotal").textContent = rupees(cart.total);
    $("checkoutBtn").disabled = cart.item_count === 0;

    const box = $("cartItems");
    box.innerHTML = "";
    if (cart.items.length === 0) {
      box.innerHTML = '<p class="muted">Your cart is empty.</p>';
      return;
    }
    cart.items.forEach((item) => {
      const row = document.createElement("div");
      row.className = "cart-item";
      row.innerHTML = `
        <span class="ci-icon"></span>
        <div><div class="ci-name"></div><div class="ci-meta"></div></div>
        <button type="button">Remove</button>`;
      row.querySelector(".ci-icon").textContent = item.icon;
      row.querySelector(".ci-name").textContent = item.name;
      row.querySelector(".ci-meta").textContent = `${item.quantity} × ${rupees(item.price)} = ${rupees(item.line_total)}`;
      row.querySelector("button").addEventListener("click", () => removeItem(item.product_id));
      box.appendChild(row);
    });
  }

  async function refreshCart() {
    try { renderCart(await api("/api/cart")); } catch (e) { /* ignore during switch */ }
  }

  async function addItem(productId, button) {
    button.disabled = true;
    try {
      const cart = await api("/api/cart/add", { method: "POST", body: JSON.stringify({ product_id: productId, quantity: 1 }) });
      renderCart(cart);
      toast("Added to cart ✓");
    } catch (e) {
      toast(e.message);
    } finally {
      button.disabled = false;
    }
  }

  async function removeItem(productId) {
    renderCart(await api("/api/cart/remove", { method: "POST", body: JSON.stringify({ product_id: productId }) }));
  }

  function openCart() {
    $("cartDrawer").classList.add("open");
    $("cartDrawer").setAttribute("aria-hidden", "false");
    $("overlay").hidden = false;
  }
  function closeCart() {
    $("cartDrawer").classList.remove("open");
    $("cartDrawer").setAttribute("aria-hidden", "true");
    $("overlay").hidden = true;
  }

  async function checkout() {
    try {
      const order = await api("/api/checkout", { method: "POST" });
      closeCart();
      renderCart({ items: [], item_count: 0, subtotal: 0, shipping: 0, total: 0 });
      $("orderId").textContent = order.order_id;
      $("orderTotal").textContent = rupees(order.total);
      $("orderServedBy").textContent = `Processed by the ${order.served_by.toUpperCase()} environment (v${order.version}).`;
      $("orderModal").hidden = false;
    } catch (e) {
      toast(e.message);
    }
  }

  // ------------------------------------------------------------------
  // Catalogue filters
  // ------------------------------------------------------------------
  let activeCategory = "all";
  function applyFilters() {
    const q = $("searchBox").value.trim().toLowerCase();
    document.querySelectorAll(".card").forEach((card) => {
      const matchText = card.dataset.name.includes(q);
      const matchCat = activeCategory === "all" || card.dataset.cat === activeCategory;
      card.style.display = matchText && matchCat ? "" : "none";
    });
  }

  // ------------------------------------------------------------------
  // Live deployment monitor (polls /api/status)
  // ------------------------------------------------------------------
  let ok = 0, fail = 0, lastColor = document.body.dataset.color, lastVersion = document.body.dataset.version;
  const MAX_TICKS = 60;

  function addTick(cls, title) {
    const tl = $("timeline");
    const tick = document.createElement("span");
    tick.className = cls;
    tick.title = title;
    tl.appendChild(tick);
    while (tl.children.length > MAX_TICKS) tl.removeChild(tl.firstChild);
  }

  function setColor(el, color) {
    el.className = el.className.replace(/env-\w+/g, "").trim() + " env-" + color;
  }

  function logEvent(text) {
    const list = $("events");
    if (list.querySelector(".muted")) list.innerHTML = "";
    const li = document.createElement("li");
    li.textContent = `${new Date().toLocaleTimeString()} — ${text}`;
    list.prepend(li);
  }

  function formatUptime(s) {
    if (s < 60) return `${s}s`;
    if (s < 3600) return `${Math.floor(s / 60)}m ${s % 60}s`;
    return `${Math.floor(s / 3600)}h ${Math.floor((s % 3600) / 60)}m`;
  }

  async function poll() {
    try {
      const s = await api("/api/status");
      ok += 1;
      addTick(s.color, `${s.color} v${s.version}`);
      $("monColor").textContent = s.color.toUpperCase();
      $("kpiColor").textContent = s.color.toUpperCase();
      $("ribbonColor").textContent = s.color.toUpperCase();
      [$("monColor"), $("kpiColor"), $("deployRibbon")].forEach((el) => setColor(el, s.color));
      $("monVersion").textContent = "v" + s.version;
      $("ribbonVersion").textContent = "v" + s.version;
      $("monBuild").textContent = s.build;
      $("ribbonBuild").textContent = s.build;
      $("monHost").textContent = s.hostname;
      $("kpiUptime").textContent = "uptime " + formatUptime(s.uptime_seconds);
      if (s.color !== lastColor || s.version !== lastVersion) {
        logEvent(`Traffic moved ${lastColor.toUpperCase()} → ${s.color.toUpperCase()} (v${lastVersion} → v${s.version})`);
        lastColor = s.color;
        lastVersion = s.version;
      }
    } catch (e) {
      fail += 1;
      addTick("fail", "request failed");
    }
    $("kpiOk").textContent = ok;
    $("kpiFail").textContent = fail;
    $("monTime").textContent = new Date().toLocaleTimeString();
  }

  // ------------------------------------------------------------------
  // Wire up events
  // ------------------------------------------------------------------
  document.querySelectorAll(".add-btn").forEach((btn) =>
    btn.addEventListener("click", () => addItem(Number(btn.dataset.id), btn)));
  $("openCart").addEventListener("click", openCart);
  $("closeCart").addEventListener("click", closeCart);
  $("overlay").addEventListener("click", closeCart);
  $("checkoutBtn").addEventListener("click", checkout);
  $("clearCart").addEventListener("click", async () => renderCart(await api("/api/cart/clear", { method: "POST" })));
  $("closeModal").addEventListener("click", () => { $("orderModal").hidden = true; });
  $("searchBox").addEventListener("input", applyFilters);
  $("filters").addEventListener("click", (e) => {
    const chip = e.target.closest(".chip");
    if (!chip) return;
    document.querySelectorAll(".chip").forEach((c) => c.classList.remove("active"));
    chip.classList.add("active");
    activeCategory = chip.dataset.cat;
    applyFilters();
  });

  refreshCart();
  poll();
  setInterval(poll, 2000);
})();
