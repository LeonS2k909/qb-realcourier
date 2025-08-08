const $ = (sel) => document.querySelector(sel);
const grid = $('#grid');
const app = $('#app');
const search = $('#search');
const pageText = $('#pageText');
const prevBtn = $('#prevBtn');
const nextBtn = $('#nextBtn');
const closeBtn = $('#closeBtn');
const modal = $('#modal');
const modalTitle = $('#modalTitle');
const modalPrice = $('#modalPrice');
const qtyInput = $('#qtyInput');
const modalClose = $('#modalClose');
const orderBtn = $('#orderBtn');

let OPEN = false;
let ITEMS = [];
let PAGE = 1;
let PER_PAGE = 12;
let MAX_QTY = 50;
let currentItem = null;

function nuiPost(name, data) {
  return fetch(`https://${GetParentResourceName()}/${name}`, {
    method: 'POST', headers: {'Content-Type':'application/json'},
    body: JSON.stringify(data || {})
  }).then(r => r.json());
}

function currency(n){ return `£${Number(n).toLocaleString()}` }

function iconFor(name) {
  // Works with qb-inventory default image path
  return `nui://qb-inventory/html/images/${name}.png`;
}

function render() {
  const totalPages = Math.max(1, Math.ceil(ITEMS.length / PER_PAGE));
  if (PAGE > totalPages) PAGE = totalPages;
  if (PAGE < 1) PAGE = 1;

  const start = (PAGE - 1) * PER_PAGE;
  const slice = ITEMS.slice(start, start + PER_PAGE);

  grid.innerHTML = '';
  slice.forEach(it => {
    const card = document.createElement('div');
    card.className = 'card';
    card.innerHTML = `
      <div class="thumb"><img src="${iconFor(it.name)}" onerror="this.src=''" alt=""></div>
      <div class="meta">
        <div class="name">${it.label}</div>
        <div class="sub">${it.name} • ${currency(it.price)}</div>
      </div>`;
    card.addEventListener('click', () => openQtyModal(it));
    grid.appendChild(card);
  });

  pageText.textContent = `Page ${PAGE}/${totalPages}`;
  prevBtn.disabled = PAGE <= 1;
  nextBtn.disabled = PAGE >= totalPages;
}

function openQtyModal(it){
  currentItem = it;
  qtyInput.value = 1;
  modalTitle.textContent = `${it.label} (${currency(it.price)} each)`;
  modalPrice.textContent = currency(it.price * 1) + ' total';
  modal.classList.remove('hidden');
}

function closeQtyModal(){
  currentItem = null;
  modal.classList.add('hidden');
}

function refreshCatalog(filter){
  return nuiPost('shop:getCatalog', { filter }).then(res => {
    if (res && res.ok) {
      ITEMS = res.items || [];
      PAGE = 1;
      render();
    }
  });
}

function openUI({ maxQty, perPage }) {
  MAX_QTY = maxQty || 50;
  PER_PAGE = perPage || 12;
  OPEN = true;
  app.classList.remove('hidden');
  search.value = '';
  refreshCatalog('');
  setTimeout(() => search.focus(), 50);
}

function closeUI(){
  OPEN = false;
  app.classList.add('hidden');
  nuiPost('shop:close', {});
}

window.addEventListener('message', (e) => {
  const data = e.data || {};
  if (data.action === 'open') openUI(data);
  if (data.action === 'close') closeUI();
});

search.addEventListener('input', (e) => {
  refreshCatalog(e.target.value || '');
});

prevBtn.addEventListener('click', () => { PAGE--; render(); });
nextBtn.addEventListener('click', () => { PAGE++; render(); });
closeBtn.addEventListener('click', () => closeUI());

modalClose.addEventListener('click', closeQtyModal);
qtyInput.addEventListener('input', () => {
  let q = Math.max(1, Math.min(MAX_QTY, parseInt(qtyInput.value || '1', 10)));
  qtyInput.value = q;
  if (currentItem) modalPrice.textContent = currency(currentItem.price * q) + ' total';
});

orderBtn.addEventListener('click', () => {
  if (!currentItem) return;
  let amount = Math.max(1, Math.min(MAX_QTY, parseInt(qtyInput.value || '1', 10)));
  nuiPost('shop:placeOrder', { name: currentItem.name, amount }).then(() => {
    closeQtyModal();
    // keep UI open for more shopping
  });
});

// Block scrolling/keys from reaching game when UI open
window.addEventListener('keydown', (e) => {
  if (!OPEN) return;
  // Prevent F5 refresh etc.
  if (['F5','F3','F12'].includes(e.key)) e.preventDefault();
});
