let items = [];
let shopping = [];
let activeFilter = "all";
let modalTarget = "inventory";
let editingItem = null;
let saveQueue = Promise.resolve();
const categoryColors = ["green", "blue", "amber", "purple"];
const $ = s => document.querySelector(s);
const $$ = s => [...document.querySelectorAll(s)];
const now = () => new Date().toISOString();
async function loadData() {
  const response = await fetch("/api/state");
  if (!response.ok) throw new Error("Could not load grocery data");
  const data = await response.json();
  items = data.items;
  shopping = data.shopping;
}
async function save() {
  const state = {items: [...items], shopping: [...shopping]};
  const request = saveQueue.then(async () => {
    const response = await fetch("/api/state", {
      method: "PUT",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify(state)
    });
    if (!response.ok) {
      const error = await response.json().catch(() => ({}));
      throw new Error(error.error || "Could not save grocery data");
    }
  });
  saveQueue = request.catch(() => {});
  return request;
}
function showDataError(message) {
  document.querySelector(".data-error")?.remove();
  document.body.insertAdjacentHTML("afterbegin", `<p class="data-error">${message}</p>`);
}
const dateLabel = d => { if(!d) return "No date"; const date = new Date(`${d}T00:00:00`); return date.toLocaleDateString("en-US",{month:"short",day:"numeric"}); };
const daysUntil = d => Math.ceil((new Date(`${d}T00:00:00`) - new Date("2026-09-13T00:00:00")) / 86400000);
const statusPill = s => s === "low" ? '<span class="pill low">Running low</span>' : s === "soon" ? '<span class="pill soon">Use soon</span>' : '<span class="pill" style="background:#eaf3eb;color:#699273">In stock</span>';
const activeItems = () => items.filter(item => !item.deletedAt);
const activeShopping = () => shopping.filter(item => !item.deletedAt);
function renderStats(){ const visibleItems=activeItems(); const visibleShopping=activeShopping(); $("#total-items").textContent=visibleItems.length; $("#low-items").textContent=visibleItems.filter(i=>i.status==="low").length; $("#expiring-items").textContent=visibleItems.filter(i=>daysUntil(i.date)<=7).length; $("#nav-count").textContent=visibleShopping.filter(i=>!i.done).length; }
function renderSidebarCategories(){
  const categories = [...new Set(["Produce", "Dairy", "Pantry", "Freezer", ...activeItems().map(item => item.category).filter(Boolean)])];
  $("#sidebar-categories").innerHTML = categories.map((category, index) => {
    const count = activeItems().filter(item => item.category === category).length;
    return `<button class="category-link" data-category="${category}"><i class="dot ${categoryColors[index % categoryColors.length]}"></i>${category}<span>${count}</span></button>`;
  }).join("");
}
function renderChart(){ const vals=[10,14,11,17,13,18,15]; $("#bars").innerHTML=vals.map((v,i)=>`<div class="bar-set"><i class="bar" style="height:${v*4.8}px"></i><i class="bar low" style="height:${(i%3===0?4:2)*4}px"></i></div>`).join(""); }
function renderCategories(){ const cats=["Produce","Dairy","Pantry","Freezer"]; const colors=["#8dbb94","#84b6c0","#dfbf76","#aa9bd0"]; const visibleItems=activeItems(); $("#category-list").innerHTML=cats.map((c,i)=>{const n=visibleItems.filter(x=>x.category===c).length; return `<div class="category-row"><span class="cat-name">${c}</span><span class="cat-track"><i style="width:${Math.max(n*16,8)}%;background:${colors[i]}"></i></span><span class="cat-count">${n}</span></div>`}).join(""); $(".category-total strong").textContent=visibleItems.length; }
function attentionMarkup(){ const list=activeItems().filter(i=>i.status!=="ok" || daysUntil(i.date)<=7).slice(0,4); $("#attention-list").innerHTML=list.length?list.map(i=>`<div class="attention-row"><span class="food-icon">${i.icon}</span><span class="food-name"><strong>${i.name}</strong><small>${i.quantity} · Best before ${dateLabel(i.date)}</small></span>${statusPill(i.status)}<span class="quantity">${i.category}</span></div>`).join(""):'<p class="empty-state">Everything looks nicely stocked.</p>'; }
function shoppingMarkup(target="#shopping-preview"){ const list=activeShopping().slice(0,target==="#shopping-preview"?3:activeShopping().length); $(target).innerHTML=list.length?list.map(i=>`<div class="shopping-row ${i.done?"done":""}"><button class="check" data-shop="${i.id}" aria-label="Mark ${i.name}">${i.done?"✓":""}</button><span class="food-name"><strong>${i.icon} &nbsp;${i.name}</strong><small>${i.note}${i.category?` · ${i.category}`:""}</small></span><span class="list-person">${i.who}</span></div>`).join(""):'<p class="empty-state">Your shopping list is empty.</p>'; }
function renderInventory(){ const query=($("#search-input")?.value||"").toLowerCase(); let filtered=activeItems().filter(i=>i.name.toLowerCase().includes(query)); if(activeFilter==="low")filtered=filtered.filter(i=>i.status==="low"); if(activeFilter==="expiring")filtered=filtered.filter(i=>daysUntil(i.date)<=7); $("#inventory-list").innerHTML=filtered.map(i=>`<div class="inventory-row"><span class="item-name"><span class="food-icon">${i.icon}</span><span><strong>${i.name}</strong><small>${i.quantity}</small></span></span><span class="inventory-cell">${i.category}</span><span class="inventory-cell">${i.quantity}</span><span class="inventory-cell">${dateLabel(i.date)}</span>${statusPill(i.status)}<span class="row-actions"><button class="row-action-button" data-edit="${i.id}" aria-label="Edit ${i.name}">✎</button><button class="row-action-button" data-delete="${i.id}" aria-label="Delete ${i.name}">×</button></span></div>`).join("") || '<p class="empty-state">No items match that filter.</p>'; }
function renderShopping(){ const visibleShopping=activeShopping(); const done=visibleShopping.filter(i=>i.done).length; $("#shopping-progress-text").textContent=`${done} of ${visibleShopping.length} items picked up`; $("#progress-bar").style.width=visibleShopping.length?`${done/visibleShopping.length*100}%`:"0%"; shoppingMarkup("#shopping-list-full"); }
function render(){ renderStats(); renderSidebarCategories(); renderChart(); renderCategories(); attentionMarkup(); shoppingMarkup(); renderInventory(); renderShopping(); }
function showView(name){ $$(".view").forEach(v=>v.classList.toggle("hidden",v.id!==`${name}-view`)); $$(".nav-item").forEach(n=>n.classList.toggle("active",n.dataset.view===name)); $("#page-title").textContent=name[0].toUpperCase()+name.slice(1); window.scrollTo(0,0); }
function openModal(target = "inventory", item = null){
  modalTarget = target;
  editingItem = item;
  $("#modal-backdrop").classList.remove("hidden");
  $("#item-form").reset();
  $("#modal-title").textContent = item ? "Edit inventory item" : "New grocery item";
  $("#item-form [name=status]").closest("label").style.display = target === "inventory" ? "block" : "none";
  if (item) {
    $("#item-form [name=name]").value = item.name || "";
    $("#item-form [name=category]").value = item.category || "Pantry";
    $("#item-form [name=quantity]").value = item.quantity || "";
    $("#item-form [name=date]").value = item.date || "";
    $("#item-form [name=status]").value = item.status || "ok";
  }
  setTimeout(()=>$("#item-form input").focus(),50);
}
function closeModal(){ $("#modal-backdrop").classList.add("hidden"); }
document.addEventListener("click",async e=>{ const view=e.target.closest("[data-view]"); if(view)showView(view.dataset.view); const cat=e.target.closest("[data-category]"); if(cat){showView("inventory"); $("#search-input").value=""; activeFilter="all"; renderInventory();} const shop=e.target.closest("[data-shop]"); if(shop){const item=shopping.find(i=>i.id==shop.dataset.shop); const wasDone=item.done; const timestamp=now(); item.done=!item.done; item.updatedAt=timestamp; let purchased; if(item.done&&!wasDone){purchased={id:Date.now(),shoppingId:item.id,createdAt:timestamp,updatedAt:timestamp,name:item.name,category:item.category||"Pantry",quantity:item.note,date:item.date||"2026-09-30",icon:item.icon||"🛒",status:"ok"};items.unshift(purchased);} if(!item.done&&wasDone){const matching=items.find(i=>i.shoppingId===item.id&&!i.deletedAt);if(matching){matching.deletedAt=timestamp;matching.updatedAt=timestamp;}} try{await save();render();}catch(error){item.done=wasDone;if(purchased)items=items.filter(i=>i!==purchased);showDataError(`Could not save that change: ${error.message}`);}} const edit=e.target.closest("[data-edit]"); if(edit){const item=items.find(i=>i.id==edit.dataset.edit);if(item)openModal("inventory",item);} const del=e.target.closest("[data-delete]"); if(del&&confirm("Remove this item from your inventory?")){const removed=items.find(i=>i.id==del.dataset.delete);if(removed){removed.deletedAt=now();removed.updatedAt=removed.deletedAt;}try{await save();render();}catch(error){if(removed){removed.deletedAt=null;}showDataError(`Could not save that change: ${error.message}`);}} const addButton=e.target.closest("#open-add, #open-add-inventory, #open-add-shopping, #quick-add-list"); if(addButton)openModal(addButton.id==="open-add-shopping"||addButton.id==="quick-add-list"?"shopping":"inventory"); if(e.target.id==="close-modal"||e.target.id==="cancel-modal"||e.target.id==="modal-backdrop")closeModal();});
$("#item-form").addEventListener("submit",async e=>{e.preventDefault();const data=new FormData(e.target);const name=data.get("name").trim();if(!name)return;const date=data.get("date")||"2026-09-30";const timestamp=now();let added;if(editingItem){const previous={...editingItem};Object.assign(editingItem,{name,category:data.get("category"),quantity:data.get("quantity"),date,status:data.get("status"),updatedAt:timestamp});try{await save();render();closeModal();}catch(error){Object.assign(editingItem,previous);showDataError(`Could not save this item: ${error.message}`);}return;}if(modalTarget==="shopping"){added={id:Date.now(),createdAt:timestamp,updatedAt:timestamp,deletedAt:null,name,note:data.get("quantity"),quantity:data.get("quantity"),category:data.get("category"),date,icon:"🛒",done:false,who:"Navin"};shopping.unshift(added);}else{added={id:Date.now(),createdAt:timestamp,updatedAt:timestamp,deletedAt:null,name,category:data.get("category"),quantity:data.get("quantity"),date,icon:"🛒",status:data.get("status")||"ok"};items.unshift(added);}try{await save();render();closeModal();}catch(error){if(modalTarget==="shopping")shopping=shopping.filter(i=>i!==added);else items=items.filter(i=>i!==added);showDataError(`Could not save this item: ${error.message}`);}});
$("#search-input").addEventListener("input",renderInventory);
$$(".filter-button").forEach(b=>b.addEventListener("click",()=>{$$(".filter-button").forEach(x=>x.classList.remove("active"));b.classList.add("active");activeFilter=b.dataset.filter;renderInventory();}));
loadData().then(render).catch(error => {
  console.error(error);
  showDataError("Could not connect to the local grocery database. Start the app with <code>npm start</code>.");
});
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible") loadData().then(render).catch(() => {});
});
setInterval(() => {
  if (document.visibilityState === "visible" && $("#modal-backdrop").classList.contains("hidden")) {
    loadData().then(render).catch(() => {});
  }
}, 10000);
