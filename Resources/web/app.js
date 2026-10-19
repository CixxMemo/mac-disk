'use strict';
const $ = id => document.getElementById(id);
const tones = {personal:{name:'Kişisel dosyalar',color:'#fae9db'},dev:{name:'Geliştirme araçları',color:'#e4e0f9'},android:{name:'SDK & simülatörler',color:'#dceef0'},ai:{name:'AI araçları',color:'#f4dfeb'},cache:{name:'Önbellekler',color:'#dfede4'},system:{name:'Sistem & diğer',color:'#e9eced'}};
const sourceCategories = ['cache','build','dependencies','models','personal','system'];
let data = null, index = new Map(), ancestors = new Map(), home = null, current = null, mode = 'folders', activeView = 'explorer', selected = new Set(), findings = [], previousFocus = null, toastTimer = null;
const element = (tag,cls,text) => {const node=document.createElement(tag);if(cls)node.className=cls;if(text!==undefined)node.textContent=text;return node;};
function icon(name){const svg=document.createElementNS('http://www.w3.org/2000/svg','svg');const use=document.createElementNS('http://www.w3.org/2000/svg','use');use.setAttribute('href','#i-'+name);svg.append(use);svg.setAttribute('aria-hidden','true');return svg;}
function amount(value){if(!Number.isFinite(value)||value<0)return ['—',''];if(value<1024)return [String(value),'B'];const units=['KiB','MiB','GiB','TiB','PiB'];let i=-1;do{value/=1024;i++;}while(value>=1024&&i<units.length-1);return [new Intl.NumberFormat('tr-TR',{maximumFractionDigits:1,minimumFractionDigits:value<10?1:0}).format(value),units[i]];}
const format = value => amount(value).join(' ');
const total = items => items.reduce((sum,item)=>sum+item.bytes,0);
const shortPath = path => home && (path===home.path||path.startsWith(home.path+'/')) ? '~'+path.slice(home.path.length) : path;
const isWithin = (child,parent) => child===parent || child.startsWith(parent==='/'?'/':parent+'/');
function toneFor(item){const p=item.path.toLowerCase();if(item.category==='cache'||item.category==='build')return 'cache';if(/android|coresimulator|iossimulator|\/xcode/.test(p))return 'android';if(item.category==='models'||/\/(\.lmstudio|\.ollama|\.gemini)(\/|$)|application support\/claude/.test(p))return 'ai';if(item.category==='dependencies'||/\/documents\/development|\/\.(vscode|cursor|qoder|gradle|nuget|rustup|pub-cache|antigravity)/.test(p))return 'dev';if(item.category==='system'||/^\/(applications|system|library|private|opt|usr)(\/|$)/.test(p))return 'system';return 'personal';}
function validate(report){
 const num=x=>typeof x==='number'&&Number.isFinite(x)&&x>=0;
 if(!report||report.app!=='Disk Atlas'||![1,2].includes(report.schema)||typeof report.demo!=='boolean'||typeof report.incomplete!=='boolean'||typeof report.scope!=='string'||typeof report.created!=='string'||!Number.isFinite(Date.parse(report.created)))throw Error('Geçerli bir Disk Atlas JSON raporu seç.');
 if(!report.disk||!['total','free','used'].every(k=>num(report.disk[k]))||!report.categories||!sourceCategories.every(k=>num(report.categories[k])))throw Error('Disk boyutları geçersiz.');
 if(!report.stats||!['entries','files','folders','errors','symlinks','otherMounts','cloudPlaceholders','hardlinkRepeats'].every(k=>num(report.stats[k])))throw Error('Tarama sayaçları geçersiz.');
 const item=x=>x&&typeof x.name==='string'&&typeof x.path==='string'&&num(x.bytes)&&sourceCategories.includes(x.category);
 if(!Array.isArray(report.largest)||report.largest.length>150||!report.largest.every(x=>item(x)&&num(x.logical))||!Array.isArray(report.candidates)||report.candidates.length>100000||!report.candidates.every(item))throw Error('Dosya veya inceleme listesi geçersiz.');
 if(!Array.isArray(report.errors)||report.errors.length>100||!report.errors.every(x=>x&&typeof x.path==='string'&&typeof x.reason==='string'))throw Error('Tarama hata listesi geçersiz.');
 let count=0;function walk(node,depth){if(depth>10||++count>100000||!item(node))throw Error('Klasör ağacı geçersiz veya çok büyük.');if(node.children!==undefined){if(!Array.isArray(node.children))throw Error('Alt klasör listesi geçersiz.');node.children.forEach(x=>walk(x,depth+1));}}
 walk(report.tree,0);
 if(report.ui){if(typeof report.ui.homePath!=='string'||!Array.isArray(report.ui.findings)||report.ui.findings.length>1000||!report.ui.findings.every(x=>item(x)&&['cache','review'].includes(x.group)&&typeof x.note==='string'))throw Error('Arayüz inceleme verileri geçersiz.');}
 return report;
}
function buildIndex(root){index=new Map();ancestors=new Map();function visit(node,chain){if(node.aggregate)return;index.set(node.path,node);ancestors.set(node.path,chain);(node.children||[]).forEach(child=>visit(child,[...chain,node]));}visit(root,[]);}
function getFindings(report){
 if(report.ui)return report.ui.findings;
 const specs=[['/Library/Caches','Uygulama önbellekleri','cache'],['/.npm/_cacache','npm önbelleği','cache'],['/.gradle/caches','Gradle önbellekleri','cache'],['/Library/Developer/CoreSimulator','iOS simülatör verileri','review'],['/Library/Android/sdk','Android SDK','review'],['/.android/avd','Android sanal cihazları','review'],['/Library/Application Support/Claude','Claude uygulama verileri','review'],['/.vscode/extensions','VS Code eklentileri','review'],['/Library/Application Support/Google','Google uygulama verileri','review'],['/.lmstudio','LM Studio bileşenleri','review'],['/Downloads','İndirilenler','review']];
 const items=specs.flatMap(([suffix,name,group])=>{const node=index.get(home.path+suffix);return node&&node.bytes?[{...node,name,group,note:'Bu konum uygulama verileri veya çalışma bileşenleri içerebilir. Dosya içerikleri okunmadı; gerekli olup olmadığı doğrulanmadı.'}]:[];});
 for(const candidate of report.candidates){if(candidate.bytes<150*1024**2||items.some(x=>isWithin(candidate.path,x.path)))continue;items.push({...candidate,group:['cache','build'].includes(candidate.category)?'cache':'review',note:typeof candidate.note==='string'?candidate.note:'Dosya yoluna göre sınıflandırıldı. Gereksiz olduğu doğrulanmadı.'});}return items;
}
function load(report){
 validate(report);data=report;buildIndex(report.tree);home=index.get(report.ui?.homePath)||[...index.values()].filter(x=>/^\/Users\/[^/]+$/.test(x.path)&&x.path!=='/Users/Shared').sort((a,b)=>b.bytes-a.bytes)[0]||report.tree;
 current=home;mode='folders';selected=new Set();findings=getFindings(report).sort((a,b)=>b.bytes-a.bytes);
 $('findingsSearch').value='';$('fileSearch').value='';$('welcome').classList.add('hidden');$('scanning').classList.add('hidden');$('dashboard').classList.remove('hidden');$('message').classList.add('hidden');
 $('scanDate').textContent=new Date(report.created).toLocaleString('tr-TR',{day:'numeric',month:'long',year:'numeric',hour:'2-digit',minute:'2-digit'});
 $('scanMeta').textContent=(report.demo?'ÖRNEK VERİ · ':'')+(report.stats.entries>=1e6?new Intl.NumberFormat('tr-TR',{maximumFractionDigits:2}).format(report.stats.entries/1e6)+' milyon':report.stats.entries.toLocaleString('tr-TR'))+' kayıt · yerel ölçüm';
 function metric(id,bytes){const [value,unit]=amount(bytes);$(id).replaceChildren(document.createTextNode(value),element('span','unit',unit));}
 metric('freeValue',report.disk.free);metric('scannedValue',report.tree.bytes);metric('cacheValue',report.categories.cache+report.categories.build);metric('homeValue',home.bytes);
 $('capacityText').textContent=format(report.disk.total)+' toplam';$('capacityFill').style.width=(report.disk.total?Math.min(100,report.disk.free/report.disk.total*100):0)+'%';
 $('filesText').textContent=report.stats.files.toLocaleString('tr-TR')+' dosya · erişilebilen kapsam';$('homeText').textContent=shortPath(home.path)+' · erişilebilen dosyalar';
 $('legend').replaceChildren(...Object.values(tones).map(t=>{const span=element('span');const dot=element('i');dot.style.background=t.color;span.append(dot,document.createTextNode(t.name));return span;}));
 if(report.demo||report.incomplete||report.fullDiskAccess==='denied'){$('message').textContent=[report.demo?'Örnek veriler Mac’ine ait değildir.':'',report.incomplete?'Kısmi tarama: süre veya kayıt sınırı aşıldı ya da tarama iptal edildi.':'',report.fullDiskAccess==='denied'?'Tam Disk Erişimi olmadan yapıldı; korumalı klasörler ölçülmedi.':''].filter(Boolean).join(' ');$('message').classList.remove('hidden');}
 renderFindings();renderFiles();renderHealth();showView('explorer');
}
function showView(view){if(!['explorer','files','health','history'].includes(view))return;if(!data){showToast('Önce bir disk raporu aç.');return;}activeView=view;document.querySelectorAll('.view').forEach(node=>node.classList.toggle('hidden',node.id!=='view-'+view));document.querySelectorAll('.nav-btn').forEach(button=>{const active=button.dataset.view===view;button.classList.toggle('active',active);if(active)button.setAttribute('aria-current','page');else button.removeAttribute('aria-current');});if(view==='explorer')requestAnimationFrame(renderMap);if(view==='history')renderHistory();}
// Squarified treemap: build rows with nearly square rectangles rather than long strips.
function squarify(items,x,y,width,height){
 const input=items.filter(item=>item.bytes>0).slice().sort((a,b)=>b.bytes-a.bytes);if(!input.length||width<=0||height<=0)return [];
 const scale=width*height/total(input);const queue=input.map(item=>({item,area:item.bytes*scale}));const output=[];let row=[],remaining=queue.slice();
 const worst=(r,side)=>{if(!r.length||side<=0)return Infinity;const sum=r.reduce((s,n)=>s+n.area,0);const max=Math.max(...r.map(n=>n.area)),min=Math.min(...r.map(n=>n.area));return Math.max(side*side*max/(sum*sum),sum*sum/(side*side*min));};
 function commit(){const sum=row.reduce((s,n)=>s+n.area,0);if(width>=height){const strip=sum/height;let cy=y;row.forEach(n=>{const h=n.area/strip;output.push({item:n.item,x,y:cy,w:strip,h});cy+=h;});x+=strip;width=Math.max(0,width-strip);}else{const strip=sum/width;let cx=x;row.forEach(n=>{const w=n.area/strip;output.push({item:n.item,x:cx,y,w,h:strip});cx+=w;});y+=strip;height=Math.max(0,height-strip);}row=[];}
 while(remaining.length){const next=remaining[0],side=Math.min(width,height);if(!row.length||worst([...row,next],side)<=worst(row,side)){row.push(next);remaining.shift();}else commit();}if(row.length)commit();return output;
}
function goTo(node){if(!node||node.aggregate)return;current=node;mode='folders';showView('explorer');}
function renderMap(){
 if(!data||activeView!=='explorer')return;
 $('foldersBtn').classList.toggle('active',mode==='folders');$('categoriesBtn').classList.toggle('active',mode==='categories');$('foldersBtn').setAttribute('aria-pressed',String(mode==='folders'));$('categoriesBtn').setAttribute('aria-pressed',String(mode==='categories'));
 const map=$('treemap');map.replaceChildren();$('breadcrumbs').replaceChildren();const chain=[...(ancestors.get(current.path)||[]),current];
 if(mode==='folders'){for(const [i,node] of chain.entries()){if(i)$('breadcrumbs').append(element('span','','›'));const button=element('button','',node===data.tree?(data.scope==='/'?'Veri birimi':node.name):node===home?'Kullanıcı klasörü':node.name);button.onclick=()=>goTo(node);if(node===current)button.setAttribute('aria-current','location');$('breadcrumbs').append(button);}}else{$('breadcrumbs').append(element('span','','Tüm tarama kapsamı / dosya türleri'));}
 $('pathTotal').textContent=format(mode==='folders'?current.bytes:data.tree.bytes);$('upBtn').disabled=mode!=='folders'||chain.length<2;$('homeBtn').disabled=mode==='folders'&&current===home;
 $('mapNote').textContent=mode==='folders'?'Bloklar ayrılan alanı gösterir. Küçük öğeler gruplandı; bir klasöre tıklayarak derine inebilirsin.':'Türler tüm tarama kapsamını gösterir. Renkler dosya yoluna göre tahmindir; içerikler okunmadı.';
 const rect=map.getBoundingClientRect();if(!rect.width||!rect.height)return;
 if(mode==='categories'){
  const items=Object.entries(data.categories).filter(([,bytes])=>bytes>0).map(([category,bytes])=>({name:{cache:'Önbellekler',build:'Derleme çıktıları',dependencies:'Bağımlılıklar',models:'AI modelleri',personal:'Kişisel & diğer',system:'Uygulama & sistem'}[category],path:data.scope,bytes,category,categoryView:true}));
  for(const tile of squarify(items,0,0,rect.width,rect.height))drawTile(map,tile,0,true);
 }else if(current.children?.some(x=>x.bytes>0)){
  for(const tile of squarify(current.children,0,0,rect.width,rect.height))drawTile(map,tile,0,false);
 }else{const empty=element('div','empty');empty.append(element('strong','','Bu düzeyde alt öğe ayrıntısı yok.'),element('span','','Boyut üst düzey toplamına dahildir.'));const button=element('button','button','Öğe ayrıntısını gör');button.onclick=()=>showDetails(current);empty.append(element('p'),button);map.append(empty);}
}
function drawTile(container,rect,depth,categoryMode){
 const {item,x,y,w,h}=rect;if(w<2||h<2)return;const tone=toneFor(item),color=tones[tone].color;
 const expandable=!categoryMode&&!item.aggregate&&item.children?.some(x=>x.bytes>0)&&depth<2&&w>125&&h>106;
 if(expandable){const group=element('div','map-group');Object.assign(group.style,{left:x+'px',top:y+'px',width:w+'px',height:h+'px',background:color});const label=element('button','group-label');label.append(element('span','name',item.name),element('span','size',format(item.bytes)));label.title=shortPath(item.path)+' · '+format(item.bytes);label.setAttribute('aria-label',item.name+', '+format(item.bytes)+', klasörü keşfet');label.onclick=()=>goTo(item);group.append(label);container.append(group);for(const tile of squarify(item.children,1,25,w-6,h-31))drawTile(group,tile,depth+1,false);return;}
 const button=element('button','map-leaf'+(tone==='cache'?' cache':'')+(w<100||h<83?' small':'')+(item.aggregate?' aggregate':'')+(selected.has(item.path)&&!item.aggregate?' selected':''));
 Object.assign(button.style,{left:x+'px',top:y+'px',width:w+'px',height:h+'px','--tile':color});button.title=shortPath(item.path)+' · '+format(item.bytes);button.setAttribute('aria-label',item.name+', '+format(item.bytes)+(item.children?.length?', klasörü keşfet':', ayrıntıları gör'));
 if(w>34&&h>25)button.append(element('span','name',item.name));if(w>58&&h>57)button.append(element('span','size',format(item.bytes)));
 button.onclick=()=>{if(!categoryMode&&!item.aggregate&&item.children?.length)goTo(item);else showDetails(item);};container.append(button);
}
function uniqueSelection(items=findings.filter(item=>selected.has(item.path))){return items.filter(item=>!items.some(other=>other.path!==item.path&&isWithin(item.path,other.path)));}
function renderSelection(){const raw=findings.filter(item=>selected.has(item.path)),items=uniqueSelection(raw);$('selectionSize').textContent=format(total(items));$('selectionCount').textContent=raw.length+' öğe seçildi'+(raw.length>items.length?' · alt klasörler bir kez sayıldı':'');$('copySelection').disabled=!items.length;$('clearSelection').disabled=!raw.length;}
function renderFindings(){
 const query=$('findingsSearch').value.trim().toLocaleLowerCase('tr-TR');const matches=findings.filter(item=>(item.name+' '+shortPath(item.path)).toLocaleLowerCase('tr-TR').includes(query));$('findingsCount').textContent=matches.length+' öğe';const list=$('findingsList');list.replaceChildren();
 for(const group of ['cache','review']){const items=matches.filter(item=>item.group===group);if(!items.length)continue;const heading=element('div','group-heading'+(group==='review'?' review':''));heading.append(element('span','',group==='cache'?'Önbellek & derleme':'Uygulama & ortam verileri'),element('span','group-size',format(total(uniqueSelection(items)))));list.append(heading);
 for(const item of items){const row=element('div','finding');const check=element('input','finding-check');check.type='checkbox';check.checked=selected.has(item.path);check.setAttribute('aria-label',item.name+' öğesini inceleme listesine seç');check.onchange=()=>{if(check.checked)selected.add(item.path);else selected.delete(item.path);renderSelection();renderMap();};const main=element('button','finding-main');main.append(element('span','finding-name',item.name),element('span','finding-path',shortPath(item.path)));main.title=item.path;main.onclick=()=>showDetails(item);const open=element('button','finding-open');open.append(icon('right'));open.setAttribute('aria-label',item.name+' ayrıntıları');open.onclick=()=>showDetails(item);row.append(check,main,element('span','finding-amount',format(item.bytes)),open);list.append(row);}}
 if(!matches.length){const empty=element('div','empty');empty.append(element('strong','','Eşleşen öğe yok.'),element('span','','Başka bir klasör veya uygulama adı dene.'));list.append(empty);}renderSelection();
}
function renderFiles(){const query=$('fileSearch').value.trim().toLocaleLowerCase('tr-TR');const files=data.largest.filter(item=>(item.name+' '+item.path).toLocaleLowerCase('tr-TR').includes(query));$('fileCount').textContent=files.length+' dosya';$('filesBody').replaceChildren();for(const file of files){const row=element('tr');const cell=element('td'),button=element('button','file-button');button.append(element('strong','',file.name),element('span','',shortPath(file.path)));button.onclick=()=>showDetails(file);cell.append(button);const kind=element('td'),badge=element('span','file-badge'),dot=element('i');dot.style.background=tones[toneFor(file)].color;badge.append(dot,document.createTextNode(tones[toneFor(file)].name));kind.append(badge);row.append(cell,kind,element('td','',format(file.logical)),element('td','',format(file.bytes)));$('filesBody').append(row);}if(!files.length){const row=element('tr'),cell=element('td','empty','Bu aramayla eşleşen dosya yok.');cell.colSpan=4;row.append(cell);$('filesBody').append(row);}}
function renderHealth(){
 $('healthSummary').textContent='Kapsam: '+(data.measurement?.scopeRoot||data.scope)+'. '+(data.incomplete?'Süre veya kayıt sınırına ulaşıldı; tarama kısmi.':'Süre veya kayıt sınırına ulaşılmadı.')+' '+data.stats.errors+' erişim/okuma hatası veya bulut klasörü atlaması kaydedildi.';
 const labels={entries:'İncelenen kayıt',files:'Normal dosya',folders:'Klasör',errors:'Hata / bulut klasörü atlaması',symlinks:'İzlenmeyen sembolik bağlantı',hardlinkRepeats:'Tekrar sayılmayan sabit bağlantı',cloudPlaceholders:'Bulut yer tutucusu',otherMounts:'İzlenmeyen farklı disk birimi'};
 $('healthMetrics').replaceChildren(...Object.entries(labels).map(([key,label])=>{const metric=element('div','health-metric');metric.append(element('strong','',data.stats[key].toLocaleString('tr-TR')),element('span','',label));return metric;}));
 $('errorList').replaceChildren(element('p','panel-subtitle','İlk '+data.errors.length+' hata / atlama kaydı'));for(const error of data.errors){const row=element('div','error-item',shortPath(error.path));row.append(element('small','',error.reason));$('errorList').append(row);}
}
function openDialog(title,eyebrow='ÖĞE AYRINTILARI'){if($('dialogBackdrop').classList.contains('hidden'))previousFocus=document.activeElement;$('dialogTitle').textContent=title;$('dialogEyebrow').textContent=eyebrow;$('dialogBody').replaceChildren();$('dialogBackdrop').classList.remove('hidden');$('closeDialog').focus();return $('dialogBody');}
function closeDialog(){$('dialogBackdrop').classList.add('hidden');previousFocus?.focus();}
function showDetails(item){
 const body=openDialog(item.name,item.categoryView?'TÜR DAĞILIMI':item.aggregate?'GRUPLANMIŞ ÖĞELER':'ÖĞE AYRINTILARI');
 body.append(element('div','detail-path',item.categoryView?'Tüm tarama kapsamı':shortPath(item.path)),element('div','detail-size',format(item.bytes)),element('div','detail-caption','Ayrılan disk alanı'+(Number.isFinite(item.logical)?' · '+format(item.logical)+' mantıksal boyut':'')));
 const reference=findings.find(x=>x.path===item.path);let note=item.note||reference?.note||'Dosya yoluna göre sınıflandırıldı. Bu alanın gereksiz olduğu veya kesin olarak boşaltılabileceği doğrulanmadı.';
 if(item.aggregate)note='Haritayı okunabilir tutmak için küçük öğeler birleştirildi. Bu blok bağımsız bir dosya veya klasör değildir; toplam alanı üst klasöre dahildir.';
 if(item.categoryView)note='Bu toplam, dosya yolu kurallarıyla bu türe atanan bütün dosyaları kapsar. İçerik okunmadığı için sınıflandırma tahmindir.';
 body.append(element('p','detail-note',note));const percent=data.tree.bytes?item.bytes/data.tree.bytes*100:0;const bar=element('div','detail-bar'),fill=element('i');fill.style.width=Math.min(100,percent)+'%';bar.append(fill);body.append(bar,element('div','detail-percent','Ölçülen dosya alanının %'+new Intl.NumberFormat('tr-TR',{maximumFractionDigits:1}).format(percent)+' kadarı'));
 const node=index.get(item.path),actions=element('div','detail-actions');if(!item.aggregate&&!item.categoryView){if(node?.children?.length){const explore=element('button','button dark','Haritada keşfet');explore.onclick=()=>{closeDialog();goTo(node);};actions.append(explore);}const copy=element('button','button','Yolu kopyala');copy.onclick=()=>copyText(item.path);actions.append(copy);if(reference){const select=element('button','button',selected.has(item.path)?'Listeden çıkar':'İnceleme listeme ekle');select.onclick=()=>{if(selected.has(item.path))selected.delete(item.path);else selected.add(item.path);select.textContent=selected.has(item.path)?'Listeden çıkar':'İnceleme listeme ekle';renderFindings();renderMap();};actions.append(select);}}body.append(actions);
 if(!item.aggregate&&!item.categoryView&&node?.children?.length){const children=element('div','detail-children');children.append(element('p','panel-subtitle','Bu konumdaki en büyük alt öğeler'));for(const child of node.children.slice(0,6)){const button=element('button','detail-child');button.append(element('span','',child.name),element('strong','',format(child.bytes)),icon('right'));button.onclick=()=>showDetails(child);children.append(button);}body.append(children);}
}
function showHelp(){const body=openDialog('Yerel bir harita. Net bir bakış.','NASIL ÇALIŞIR?');const help=element('div','help-content');const sections=[['Gerçek ölçüm, yerel görünüm','Bu arayüz mevcut Disk Atlas JSON taramasını gösterir. HTML sayfası diske kendiliğinden erişmez. Üstteki tarih, verilerin ölçüldüğü zamanı belirtir.'],['Haritayı keşfet','Klasörler alanlarıyla orantılı çizilir; alt klasörler aynı blok içinde görünür. Bir bloğa tıkla, klasör yoluyla geri dön veya Türler görünümünü aç. Haritadaki küçük öğeler birleştirilir; ölçülen toplamları korunur.'],['Kendi inceleme listen','Sağdaki kutuları işaretleyerek yalnızca bir liste oluşturursun. Listeyi kopyalamak dosyalarda işlem yapmaz. Bir üst klasör ve onun alt klasörü birlikte seçilirse alan bir kez sayılır.'],['Boyutları doğru yorumla','Ayrılan alan, dosyanın diskte kapladığı blokların toplamıdır. Mantıksal boyut farklı olabilir. APFS klonları, korumalı alanlar ve anlık görüntüler nedeniyle bu rapor tam disk toplamıyla eşit olmak zorunda değildir.'],['Yeni veriyle güncelle','Yeni bir Disk Atlas JSON raporu oluştuğunda Rapor aç düğmesiyle seçebilirsin. Rapor tarayıcı belleğinde işlenir; sunucuya gönderilmez. Mevcut taramadan arayüzü yeniden oluşturmak için proje klasöründe python3 -B build_ui.py çalıştırılabilir.']];if(bridge){sections[0]=['Gerçek ölçüm, yerel görünüm','Disk Atlas, Tara dediğinde Mac’indeki dosyaların yalnızca adını, yolunu ve boyutunu okur; dosyaların içine bakmaz. Sonuçlar bu Mac’te kalır, ağa hiçbir şey gönderilmez. Üstteki tarih, verilerin ölçüldüğü zamanı belirtir.'];sections[4]=['Taramalar ve izin','Her tarama bu Mac’e kaydedilir ve uygulama açıldığında en sonuncusu gösterilir. Tam Disk Erişimi olmadan korumalı klasörler okunamaz ve sonuç kısmi olur. Eski Python raporlarını Rapor aç düğmesiyle de görüntüleyebilirsin.'];}
 for(const [title,text] of sections)help.append(element('h3','',title),element('p','',text));body.append(help);}
function showToast(text){clearTimeout(toastTimer);$('toast').textContent=text;$('toast').classList.remove('hidden');toastTimer=setTimeout(()=>$('toast').classList.add('hidden'),3500);}
async function copyText(text){try{if(navigator.clipboard?.writeText)await navigator.clipboard.writeText(text);else{const area=element('textarea');area.value=text;area.style.position='fixed';area.style.left='-9999px';document.body.append(area);area.select();const copied=document.execCommand('copy');area.remove();if(!copied)throw Error('clipboard');}showToast('Kopyalandı. Dosyalarda işlem yapılmadı.');}catch{showToast('Tarayıcı kopyalamayı engelledi. Kopyalamak için metni seçebilirsin.');}}
function selectionText(){return 'Disk Atlas — yalnızca inceleme listesi\nÖlçüm: '+data.created+'\nKesin kazanılacak alan veya silme talimatı değildir.\n\n'+uniqueSelection().map(item=>item.path+' | '+format(item.bytes)).join('\n')+'\n\nToplam ayrılan alan: '+format(total(uniqueSelection()));}
document.querySelectorAll('.nav-btn').forEach(button=>button.onclick=()=>showView(button.dataset.view));
$('foldersBtn').onclick=()=>{mode='folders';renderMap();};$('categoriesBtn').onclick=()=>{mode='categories';renderMap();};$('upBtn').onclick=()=>{const chain=ancestors.get(current.path)||[];if(chain.length)goTo(chain.at(-1));};$('homeBtn').onclick=()=>goTo(home);
$('findingsSearch').oninput=renderFindings;$('fileSearch').oninput=renderFiles;
$('clearSelection').onclick=()=>{selected.clear();renderFindings();renderMap();};$('copySelection').onclick=()=>copyText(selectionText());
$('coverageBtn').onclick=()=>showView('health');$('helpBtn').onclick=showHelp;
$('importBtn').onclick=$('welcomeImport').onclick=()=>$('fileInput').click();
$('fileInput').onchange=async event=>{const file=event.target.files[0];if(!file)return;try{if(file.size>40*1024**2)throw Error('JSON raporu en fazla 40 MiB olabilir.');load(JSON.parse(await file.text()));}catch(error){$('message').textContent='Rapor açılamadı: '+error.message;$('message').classList.remove('hidden');}finally{event.target.value='';}};
$('closeDialog').onclick=closeDialog;$('dialogBackdrop').onclick=event=>{if(event.target===$('dialogBackdrop'))closeDialog();};
document.addEventListener('keydown',event=>{if($('dialogBackdrop').classList.contains('hidden'))return;if(event.key==='Escape')closeDialog();if(event.key==='Tab'){const buttons=[...$('dialogBackdrop').querySelectorAll('button:not([disabled]),input:not([disabled]),a[href]')];const first=buttons[0],last=buttons.at(-1);if(event.shiftKey&&document.activeElement===first){event.preventDefault();last.focus();}else if(!event.shiftKey&&document.activeElement===last){event.preventDefault();first.focus();}}});
new ResizeObserver(()=>{if(data&&activeView==='explorer')requestAnimationFrame(renderMap);}).observe($('treemap'));

// ---- Yerel (WebKit) arka uç: köprü, tarama ve izin ekranları ----
const bridge = (() => {
  const handler = window.webkit?.messageHandlers?.diskatlas;
  if (!handler) return null;
  let counter = 0;
  return {
    async request(type, payload = {}) {
      const response = JSON.parse(await handler.postMessage(JSON.stringify({ id: String(++counter), type, payload })));
      if (!response.ok) throw Error(response.error || 'İşlem başarısız oldu.');
      return response.data;
    }
  };
})();
let scanning = false, permissionState = 'unknown';
const clock = seconds => String(Math.floor(seconds / 60)).padStart(2, '0') + ':' + String(Math.floor(seconds % 60)).padStart(2, '0');
function updatePermissionBanner() {
  const dashboardShown = !$('dashboard').classList.contains('hidden');
  $('permissionBanner').classList.toggle('hidden', !bridge || permissionState === 'granted' || !dashboardShown || scanning);
}
const showMessage = text => { $('message').textContent = text; $('message').classList.remove('hidden'); };
function showIdleScreen() { if (data) $('dashboard').classList.remove('hidden'); else $('welcome').classList.remove('hidden'); updatePermissionBanner(); }
function setScanning(on) {
  scanning = on; $('scanning').classList.toggle('hidden', !on); $('scanBtn').disabled = on;
  if (on) { $('welcome').classList.add('hidden'); $('dashboard').classList.add('hidden'); $('message').classList.add('hidden'); }
  updatePermissionBanner();
}
async function startScan() {
  if (!bridge || scanning) return;
  setScanning(true); $('scanProgressText').textContent = 'Tarama başlıyor…';
  try { await bridge.request('startScan', { scope: 'data' }); }
  catch (error) { setScanning(false); showMessage('Tarama başlatılamadı: ' + error.message); showIdleScreen(); }
}
async function cancelScan() {
  try { await bridge.request('cancelScan'); $('scanProgressText').textContent = 'Tarama durduruluyor…'; }
  catch (error) { showMessage('Tarama durdurulamadı: ' + error.message); }
}
async function openSavedScan(id) { load(await bridge.request('loadScan', { id })); updatePermissionBanner(); }
window.diskAtlasEvent = async event => {
  if (event.event === 'scanProgress') {
    $('scanProgressText').textContent = clock(event.elapsed) + ' · ' + event.records.toLocaleString('tr-TR') + ' kayıt · ' + event.errors.toLocaleString('tr-TR') + ' erişilemeyen · ' + event.folder;
  } else if (event.event === 'scanDone') {
    setScanning(false);
    try { await openSavedScan(event.id); } catch (error) { showMessage('Rapor açılamadı: ' + error.message); showIdleScreen(); }
  } else if (event.event === 'scanFailed') {
    setScanning(false); showMessage(event.message || 'Tarama başarısız oldu.'); showIdleScreen();
  }
};
function renderPermission(status) {
  const texts = {
    granted: ['Tam Disk Erişimi var', 'Tüm klasörler okunabilir; tarama eksiksiz olur.'],
    denied: ['Tam Disk Erişimi yok', 'Mail, Mesajlar, Safari gibi korumalı klasörler okunamaz, bu yüzden tarama kısmi olacak. Ayrıca macOS Masaüstü, Belgeler ve İndirilenler için ayrı izin sorabilir. İstersen Ayarlar’da Disk Atlas’a Tam Disk Erişimi ver ve uygulamayı yeniden aç. Uygulamayı güncellediysen izin açık görünse de çalışmayabilir; Disk Atlas’ı listede kapatıp yeniden aç.'],
    unknown: ['Tam Disk Erişimi bilinmiyor', 'İzin durumu belirlenemedi. Tarama yine çalışır; korumalı klasörler okunamazsa sonuç kısmi olur.']
  };
  const [title, text] = texts[status] || texts.unknown;
  $('permissionTitle').textContent = title; $('permissionText').textContent = text;
  $('openSettingsBtn').classList.toggle('hidden', status === 'granted');
  permissionState = status;
  $('bannerTitle').textContent = status === 'denied' ? 'Tam Disk Erişimi yok.' : 'Tam Disk Erişimi bilinmiyor.';
  $('bannerText').textContent = status === 'denied' ? 'Korumalı klasörler okunamaz; yeni taramalar kısmi olur.' : 'İzin durumu belirlenemedi; yeni taramalar kısmi olabilir.';
  updatePermissionBanner();
}
async function bootNative() {
  $('scanBtn').classList.remove('hidden'); $('historyNav').classList.remove('hidden'); $('welcomeFile').classList.add('hidden'); $('welcomeNative').classList.remove('hidden');
  try { const info = await bridge.request('appInfo'); $('appInfoText').textContent = 'Disk Atlas ' + info.version + ' · macOS ' + info.macOS; } catch {}
  try { renderPermission((await bridge.request('permissionStatus')).status); } catch { renderPermission('unknown'); }
  let scans = [];
  try { scans = await bridge.request('listScans'); } catch (error) { showMessage('Tarama listesi okunamadı: ' + error.message); }
  if (scans.length) {
    try { await openSavedScan(scans[0].id); return; } catch (error) { showMessage('Son tarama açılamadı: ' + error.message); }
  }
  $('welcome').classList.remove('hidden');
}
$('scanBtn').onclick = $('startScanBtn').onclick = startScan;
$('cancelScanBtn').onclick = cancelScan;
$('openSettingsBtn').onclick = $('openSettingsBanner').onclick = () => bridge?.request('openFullDiskAccess').catch(error => showMessage('Ayarlar açılamadı: ' + error.message));
// ---- Geçmiş ve karşılaştırma ----
let historyScans = [], picked = [], compareResult = null, compareFilterName = 'all';
const dateLabel = value => new Date(value).toLocaleString('tr-TR', { day: 'numeric', month: 'long', year: 'numeric', hour: '2-digit', minute: '2-digit', second: '2-digit' });
const signed = delta => (delta > 0 ? '+' : delta < 0 ? '−' : '') + format(Math.abs(delta));
const filterNames = ['all', 'grew', 'shrank', 'newgone', 'uncertain'];
const setFilterButtons = () => filterNames.forEach(name => $('filter-' + name).classList.toggle('active', name === compareFilterName));
const statusLabels = { grew: 'Büyüdü', shrank: 'Küçüldü', new: 'Yeni / 1 MiB üstüne çıktı', gone: 'Kalktı / 1 MiB altına indi', uncertain: 'Belirsiz' };
async function renderHistory() {
  if (!bridge) return;
  try { historyScans = await bridge.request('listScans'); }
  catch (error) { showMessage('Geçmiş okunamadı: ' + error.message); return; }
  picked = picked.filter(id => historyScans.some(scan => scan.id === id));
  drawHistory();
}
function drawHistory() {
  const list = $('historyList'); list.replaceChildren();
  if (!historyScans.length) list.append(element('div', 'history-empty', 'Henüz kayıtlı tarama yok.'));
  const boxes = new Map();
  for (const scan of historyScans) {
    const row = element('div', 'history-row');
    const box = element('input'); box.type = 'checkbox'; box.checked = picked.includes(scan.id); box.disabled = scan.comparable === false;
    box.setAttribute('aria-label', dateLabel(scan.created) + ' taramasını seç');
    boxes.set(scan.id, box);
    // Liste yeniden çizilmez (klavye odağı kaybolmasın): üçüncü seçimde en eski seçim kutusu kaldırılır.
    box.onchange = () => {
      picked = picked.filter(id => id !== scan.id);
      if (box.checked) picked.push(scan.id);
      while (picked.length > 2) boxes.get(picked.shift()).checked = false;
      $('compareBtn').disabled = picked.length !== 2;
    };
    const main = element('div', 'history-main'), title = element('div', '', dateLabel(scan.created));
    if (scan.incomplete) title.append(element('span', 'badge', 'Kısmi'));
    if (scan.fullDiskAccess === 'denied') title.append(element('span', 'badge', 'İzinsiz'));
    if (scan.comparable === false) title.append(element('span', 'badge', 'Karşılaştırılamaz (eski sürüm)'));
    main.append(title, element('div', 'history-meta', format(scan.allocatedBytes) + ' ölçüldü · kapsam ' + scan.scope));
    const open = element('button', 'text-button', 'Aç'), remove = element('button', 'text-button', 'Sil');
    open.onclick = () => openScan(scan.id);
    remove.onclick = () => confirmDelete(scan);
    row.append(box, main, open, remove);
    list.append(row);
  }
  $('compareBtn').disabled = picked.length !== 2;
}
async function openScan(id) {
  try { await openSavedScan(id); showView('explorer'); }
  catch (error) { showMessage('Tarama açılamadı: ' + error.message); }
}
function confirmDelete(scan) {
  const body = openDialog('Taramayı sil', 'İŞLEM ONAYI');
  body.append(element('p', '', dateLabel(scan.created) + ' tarihli tarama kaydı silinecek. Bu yalnızca Disk Atlas’ın kendi kaydıdır; Mac’indeki dosyalarına dokunulmaz.'));
  const actions = element('div', 'dialog-actions'), cancel = element('button', 'button', 'Vazgeç'), confirm = element('button', 'button dark', 'Sil');
  cancel.onclick = closeDialog;
  confirm.onclick = async () => {
    closeDialog();
    try {
      await bridge.request('deleteScan', { id: scan.id });
      picked = picked.filter(id => id !== scan.id);
      if (compareResult && (compareResult.olderId === scan.id || compareResult.newerId === scan.id)) { compareResult = null; $('compareResult').classList.add('hidden'); }
      await renderHistory(); showToast('Tarama kaydı silindi.');
    } catch (error) { showMessage('Tarama silinemedi: ' + error.message); }
  };
  actions.append(cancel, confirm); body.append(actions);
}
async function runCompare() {
  if (picked.length !== 2) return;
  try { compareResult = await bridge.request('compare', { older: picked[0], newer: picked[1] }); }
  catch (error) { compareResult = null; $('compareResult').classList.add('hidden'); showMessage('Karşılaştırılamadı: ' + error.message); return; }
  $('message').classList.add('hidden'); compareFilterName = 'all'; $('compareSearch').value = '';
  setFilterButtons();
  $('compareResult').classList.remove('hidden'); drawCompare();
}
function drawCompare() {
  const { diff, olderCreated, newerCreated } = compareResult;
  $('compareSubtitle').textContent = dateLabel(olderCreated) + ' → ' + dateLabel(newerCreated);
  const card = (label, value, note) => { const stat = element('div', 'stat'); stat.append(element('div', 'stat-label', label), element('div', 'stat-value', signed(value)), element('div', 'stat-desc', note)); return stat; };
  $('compareSummary').replaceChildren(
    card('Ölçülen dosya farkı', diff.measuredDelta, 'İki taramada ölçülen toplam alan'),
    card('Disk doluluk farkı', diff.diskUsedDelta, 'Diskin kullanılan alanındaki değişim'),
    card('Açıklanamayan fark', diff.unexplained, 'Anlık görüntüler, korumalı alanlar ve taramalar arası değişimler'));
  $('compareWarnings').replaceChildren(...diff.warnings.map(text => element('div', 'notice', text)));
  const query = $('compareSearch').value.trim().toLocaleLowerCase('tr-TR');
  const groups = { all: () => true, grew: i => i.status === 'grew', shrank: i => i.status === 'shrank', newgone: i => i.status === 'new' || i.status === 'gone', uncertain: i => i.status === 'uncertain' };
  const shown = diff.items.filter(item => groups[compareFilterName](item) && item.path.toLocaleLowerCase('tr-TR').includes(query));
  $('compareCount').textContent = shown.length + ' / ' + diff.totalItems + ' klasör';
  $('compareBody').replaceChildren();
  for (const item of shown) {
    const row = element('tr');
    const num = (text, cls) => element('td', 'num' + (cls ? ' ' + cls : ''), text);
    const status = element('td', '', statusLabels[item.status] + (item.reason ? ' · ' + item.reason : ''));
    const path = element('td', '', shortPath(item.path)); path.setAttribute('title', item.path);
    row.append(path, num(item.before == null ? '—' : format(item.before)), num(item.after == null ? '—' : format(item.after)),
               num(signed(item.delta), item.delta > 0 ? 'pos' : 'neg'), status);
    $('compareBody').append(row);
  }
  if (!shown.length) { const row = element('tr'), cell = element('td', 'empty', 'Bu filtreyle eşleşen klasör yok.'); cell.colSpan = 5; row.append(cell); $('compareBody').append(row); }
}
$('compareBtn').onclick = runCompare;
$('compareSearch').oninput = () => compareResult && drawCompare();
filterNames.forEach(name => $('filter-' + name).onclick = () => { compareFilterName = name; setFilterButtons(); if (compareResult) drawCompare(); });
window.diskAtlasReady = bridge ? bootNative() : Promise.resolve($('welcome').classList.remove('hidden'));
