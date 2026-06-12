// Cart state
let cart = JSON.parse(localStorage.getItem('cart') || '[]');

function updateCartCount() {
  const count = cart.reduce((sum, item) => sum + item.qty, 0);
  document.querySelectorAll('#cartCount').forEach(el => {
    el.textContent = count;
    el.style.display = count > 0 ? 'flex' : 'none';
  });
}

function addToCart(name, price, qty = 1) {
  const existing = cart.find(i => i.name === name);
  if (existing) {
    existing.qty += qty;
  } else {
    cart.push({ name, price, qty });
  }
  localStorage.setItem('cart', JSON.stringify(cart));
  updateCartCount();
  showToast(`"${name}" added to cart!`);
}

function showToast(msg) {
  const toast = document.getElementById('cartToast');
  const msgEl = document.getElementById('cartToastMsg');
  if (!toast) return;
  msgEl.textContent = msg;
  toast.classList.add('show');
  clearTimeout(toast._timeout);
  toast._timeout = setTimeout(() => toast.classList.remove('show'), 3000);
}

// Filter & Sort
function filterProducts() {
  const val = document.getElementById('filterSelect')?.value || 'all';
  const cards = document.querySelectorAll('.product-card');
  let visible = 0;
  cards.forEach(card => {
    const show = val === 'all' || card.dataset.type === val;
    card.classList.toggle('hidden', !show);
    if (show) visible++;
  });
  const countEl = document.getElementById('productCount');
  if (countEl) countEl.textContent = `${visible} product${visible !== 1 ? 's' : ''}`;
}

function sortProducts() {
  const val = document.getElementById('sortSelect')?.value || 'featured';
  const grid = document.getElementById('productsGrid');
  if (!grid) return;
  const cards = Array.from(grid.querySelectorAll('.product-card'));

  cards.sort((a, b) => {
    const pa = +a.dataset.price, pb = +b.dataset.price;
    const da = a.dataset.date || '', db = b.dataset.date || '';
    const sa = +a.dataset.sales || 0, sb = +b.dataset.sales || 0;
    if (val === 'price-asc') return pa - pb;
    if (val === 'price-desc') return pb - pa;
    if (val === 'newest') return db.localeCompare(da);
    if (val === 'best-selling') return sb - sa;
    return 0;
  });
  cards.forEach(c => grid.appendChild(c));
}

function setView(view) {
  const grid = document.getElementById('productsGrid');
  if (!grid) return;
  grid.classList.toggle('list-view', view === 'list');
  document.getElementById('gridViewBtn')?.classList.toggle('active', view === 'grid');
  document.getElementById('listViewBtn')?.classList.toggle('active', view === 'list');
}

// Load More (simulate)
let visibleCount = 12;
function loadMore() {
  const hidden = document.querySelectorAll('.product-card.extra-hidden');
  hidden.forEach((c, i) => {
    if (i < 4) c.classList.remove('extra-hidden');
  });
  if (document.querySelectorAll('.product-card.extra-hidden').length === 0) {
    const btn = document.querySelector('.btn-load-more');
    if (btn) btn.style.display = 'none';
  }
}

// Search toggle
document.getElementById('searchToggle')?.addEventListener('click', () => {
  document.getElementById('searchBar')?.classList.toggle('open');
});
document.getElementById('searchClose')?.addEventListener('click', () => {
  document.getElementById('searchBar')?.classList.remove('open');
});

// Mobile nav toggle
document.getElementById('navToggle')?.addEventListener('click', () => {
  document.getElementById('mobileNav')?.classList.toggle('open');
});

// Quantity buttons (product page)
function changeQty(delta) {
  const input = document.getElementById('qtyNum');
  if (!input) return;
  const val = Math.max(1, parseInt(input.value) + delta);
  input.value = val;
}

// Tabs (product page)
function showTab(id) {
  document.querySelectorAll('.tab-btn').forEach(btn => {
    btn.classList.toggle('active', btn.dataset.tab === id);
  });
  document.querySelectorAll('.tab-panel').forEach(panel => {
    panel.classList.toggle('active', panel.id === id);
  });
}

// Cart page
function renderCart() {
  const container = document.getElementById('cartItems');
  if (!container) return;

  if (cart.length === 0) {
    container.innerHTML = `
      <div class="cart-empty">
        <i class="fas fa-shopping-bag"></i>
        <h3>Your cart is empty</h3>
        <p>Add some wonderful learning materials!</p>
        <a href="index.html">Continue Shopping</a>
      </div>`;
    document.getElementById('summarySubtotal').textContent = '₱0.00';
    document.getElementById('summaryTotal').textContent = '₱0.00';
    return;
  }

  const emojis = ['🦋','🐸','🌻','🐔','🐝','🌿','🦟','🐛','🌱','🐠','🦎','🐌'];
  const colors = [
    'linear-gradient(135deg,#d4f1c0,#a8e6a1)',
    'linear-gradient(135deg,#c0e8f1,#7ecfe8)',
    'linear-gradient(135deg,#fde8b0,#fbc85a)',
    'linear-gradient(135deg,#ffd6d6,#ffaaaa)',
    'linear-gradient(135deg,#f0d4f5,#d89fe8)',
    'linear-gradient(135deg,#c8f5e0,#6ddba7)',
  ];

  let html = '';
  cart.forEach((item, i) => {
    const emoji = emojis[i % emojis.length];
    const bg = colors[i % colors.length];
    html += `
      <div class="cart-item">
        <div class="cart-item-img" style="background:${bg}">${emoji}</div>
        <div class="cart-item-info">
          <div class="cart-item-title">${item.name}</div>
          <div class="cart-item-type">Qty: ${item.qty}</div>
          <button class="cart-item-remove" onclick="removeFromCart(${i})"><i class="fas fa-times"></i> Remove</button>
        </div>
        <div class="cart-item-price">₱${(item.price * item.qty).toLocaleString()}.00</div>
      </div>`;
  });
  container.innerHTML = html;

  const subtotal = cart.reduce((s, i) => s + i.price * i.qty, 0);
  const shipping = subtotal >= 999 ? 0 : 80;
  const total = subtotal + shipping;

  if (document.getElementById('summarySubtotal'))
    document.getElementById('summarySubtotal').textContent = `₱${subtotal.toLocaleString()}.00`;
  if (document.getElementById('summaryShipping'))
    document.getElementById('summaryShipping').textContent = shipping === 0 ? 'FREE' : `₱${shipping}.00`;
  if (document.getElementById('summaryTotal'))
    document.getElementById('summaryTotal').textContent = `₱${total.toLocaleString()}.00`;
}

function removeFromCart(index) {
  cart.splice(index, 1);
  localStorage.setItem('cart', JSON.stringify(cart));
  updateCartCount();
  renderCart();
}

function subscribeNewsletter(e) {
  e.preventDefault();
  const input = e.target.querySelector('input');
  alert(`Thank you for subscribing with ${input.value}! 🌸`);
  input.value = '';
}

// Init
updateCartCount();
renderCart();
