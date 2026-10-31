(function(){
const panel=document.querySelector("#t3-panel");if(!panel)return;
const form=document.querySelector("#t3-form"),server=document.querySelector("#t3-server"),code=document.querySelector("#t3-code"),message=document.querySelector("#t3-message"),connectButton=document.querySelector("#t3-connect"),repair=document.querySelector("#t3-repair"),disconnect=document.querySelector("#t3-disconnect");
let current=null;
async function api(path,options={}){const headers={Accept:"application/json",...(options.headers||{})},csrf=window.__samCsrfToken;if(csrf&&options.method&&options.method!=="GET")headers["X-CSRF-Token"]=csrf;const response=await fetch(path,{credentials:"same-origin",...options,headers});const body=await response.json().catch(()=>({}));if(!response.ok)throw new Error(body.error?.message||body.message||"This action could not be completed.");return body}
function day(iso){const value=new Date(iso||"");return isNaN(value)?"":value.toLocaleDateString(undefined,{month:"short",day:"numeric",year:"numeric"})}
function ago(iso){const value=new Date(iso||"");if(isNaN(value))return"";const seconds=Math.max(0,(Date.now()-value.getTime())/1000);if(seconds<60)return"just now";if(seconds<3600)return`${Math.floor(seconds/60)} min ago`;if(seconds<86400)return`${Math.floor(seconds/3600)} h ago`;return day(iso)}
function setState(text,tone){const state=document.querySelector("#t3-state");state.className="state "+(tone||"");state.querySelector("span").textContent=text}
function render(view){current=view;const connected=!!view.connected,paired=!!view.credentialPresent,health=view.healthState||"unconfigured";
document.querySelector("#t3-title").textContent=paired?(view.label?`T3 Code · ${view.label}`:"T3 Code"):"T3 Code";
const parts=[];if(paired&&view.serverUrl)parts.push(view.serverUrl);if(paired&&view.expiresAt)parts.push(`access until ${day(view.expiresAt)}`);if(connected&&view.lastSyncAt)parts.push(`synced ${ago(view.lastSyncAt)}`);
const counts=view.counts;if(connected&&counts){const bits=[];if(counts.needsYou)bits.push(`${counts.needsYou} need you`);if(counts.working)bits.push(`${counts.working} working`);if(counts.error)bits.push(`${counts.error} failed`);bits.push(`${view.threadCount??0} threads`);parts.push(bits.join(", "))}
document.querySelector("#t3-detail").textContent=view.detail||(parts.length?parts.join(" · "):"Not connected. Pair once with a code from T3 Code on your Mac.");
if(health==="ready")setState("Connected","ready");else if(health==="failed")setState("Unreachable","error");else if(health==="reauth")setState("Pair again","error");else setState("Not connected","");
disconnect.hidden=!paired;repair.hidden=!connected;form.hidden=connected&&!form.dataset.open;
if(!server.value)server.value=view.serverUrl||view.defaultServerUrl||"http://192.168.1.183:3774"}
async function load(){try{render(await api("/v1/management/t3"))}catch(error){document.querySelector("#t3-detail").textContent=error.message;setState("Unavailable","error")}}
form.addEventListener("submit",async event=>{event.preventDefault();message.textContent="";connectButton.disabled=true;connectButton.textContent="Connecting…";try{const body=await api("/v1/management/t3/connect",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({serverUrl:server.value.trim(),pairingCode:code.value.trim()})});code.value="";delete form.dataset.open;render(body);message.className="support";message.textContent="Connected. The R1 now follows your T3 threads."}catch(error){message.className="error";message.textContent=error.message}finally{connectButton.disabled=false;connectButton.textContent="Connect T3 Code"}});
repair.onclick=()=>{form.dataset.open="1";form.hidden=false;message.textContent="";code.focus()};
disconnect.onclick=async()=>{if(!confirm("Disconnect T3 Code from this R1? The access token is deleted from the device."))return;message.textContent="";try{const body=await api("/v1/management/t3/disconnect",{method:"POST",headers:{"Content-Type":"application/json"},body:"{}"});delete form.dataset.open;render(body);message.className="support";message.textContent=body.revokeHint||"Disconnected."}catch(error){message.className="error";message.textContent=error.message}};
document.addEventListener("sam:page",event=>{if(event.detail==="connections")load()});
setInterval(()=>{if(current&&current.connected&&!panel.closest("section").hidden&&panel.closest(".page.active"))load()},15000);
})();
