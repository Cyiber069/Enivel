/* Live part of a school page: verified routes for this school (public fields only) or the waitlist form. */
(function(){
  const URL_='https://kakzsotpfzgghlfanaut.supabase.co',KEY='sb_publishable_189hy2dtUN4ihB6V8Wfdvw__gECogUx';
  const box=document.getElementById('live');if(!box)return;const school=box.dataset.school;
  const e=s=>String(s==null?'':s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const R=n=>{const [a,b]=Number(n).toFixed(2).split('.');return 'R'+a.replace(/\B(?=(\d{3})+(?!\d))/g,' ')+'.'+b};
  function client(){return window.supabase&&window.supabase.createClient?window.supabase.createClient(URL_,KEY,{auth:{persistSession:false}}):null}
  function form(){return `<form id="wl" class="card"><b>Join the waitlist for ${e(school)}</b><p class="muted" style="margin:4px 0 8px">We'll WhatsApp you when a verified driver starts at this school.</p>
    <div class="row2"><input name="name" placeholder="Your name" required autocomplete="name"><input name="phone" placeholder="WhatsApp number" inputmode="tel" required autocomplete="tel"></div>
    <div class="row2"><input name="area" placeholder="Your suburb / area"><select name="kids"><option value="1">1 child</option><option value="2">2 children</option><option value="3">3 children</option><option value="4">4 children</option></select></div>
    <button class="btn" style="margin-top:8px">Join the waitlist</button><p class="muted" style="font-size:.8rem">We only use your number for transport to this school. <a href="/?page=privacy">Privacy</a></p></form>`}
  async function run(){const sb=client();if(!sb){box.innerHTML+=`<p><a class="btn" href="/?school=${encodeURIComponent(school)}">Search on Enivel</a></p>`;return}
    let routes=[];try{const r=await sb.rpc('school_routes',{p_school:school});routes=r.data||[]}catch(x){}
    const head='<h2>Drivers for this school</h2>';
    if(!routes.length)box.innerHTML=head+`<p><b>No Enivel driver for ${e(school)} yet.</b> Join the waitlist: the more parents wait at a school, the faster we find a driver.</p>`+form();
    else box.innerHTML=head+routes.map(x=>{const fee=x.price?Math.round(x.price*5)/100:0;return `<div class="card"><b>${e(x.title||'Route')}</b><div class="muted" style="font-size:.88rem">${e(x.driverFirst||'Driver')} · verified${x.vehicle?' · '+e([x.vehicle.make,x.vehicle.model].filter(Boolean).join(' ')):''}</div>
      <div style="margin-top:6px">${x.price?`<b>${R(x.price+fee)}</b> a month incl. 5% fee · `:''}${e(x.areas||'')}${x.pickupTime?' · pickup from '+e(x.pickupTime):''} · ${x.free==null?'':x.free>0?`<span class="ok">${x.free} open seat${x.free>1?'s':''}</span>`:'<span class="bad">full</span>'}</div>
      <a class="btn" style="margin-top:8px" href="/?signup=parent">Book a seat</a></div>`}).join('')+`<p class="muted">No route that fits?</p>`+form();
    const f=document.getElementById('wl');if(f)f.onsubmit=async ev=>{ev.preventDefault();const b=f.querySelector('button');b.disabled=true;let d=null;
      try{const r=await sb.rpc('school_waitlist_join',{p_name:f.name.value,p_phone:f.phone.value,p_school:school,p_area:f.area.value,p_kids:+f.kids.value,p_lang:'en'});d=r.data}catch(x){}
      if(!d||!d.ok){b.disabled=false;alert(d&&d.error==='phone'?'Please enter a South African cell number, e.g. 082 123 4567.':'Could not join right now, please try again.');return}
      const share=`Need school transport for ${school}? I've joined the Enivel waitlist for verified drivers. Join too so a driver starts sooner: ${location.href}`;
      f.outerHTML=`<div class="card"><b class="ok">You're on the waitlist.</b><p>${d.waiting>1?`<b>${d.waiting}</b> parents are now waiting for ${e(school)}. `:''}We'll WhatsApp you when a verified driver starts. Share it with other parents at the school:</p><a class="btn" href="https://wa.me/?text=${encodeURIComponent(share)}" target="_blank" rel="noopener">Share on WhatsApp</a></div>`}}
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',run);else run();
})();
