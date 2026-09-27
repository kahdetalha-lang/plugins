(() => {
  const ids = ['width','height','joint','thickness','stagger','waste_percent'];
  const decimalIds = ['width','height','joint','thickness','waste_percent'];
  let state = {};
  let timer;
  let editingPresetId = null;
  let finalReport = null;
  let reportSaveTimer = null;
  let selectedAreaM2 = 0;
  let generating = false;
  let selectedFace = false;
  let editingLayout = false;
  let documentationGroupId = null;
  let documentationNameTimer = null;
  let documentationArrowCount = 2;
  const el = id => document.getElementById(id);
  const renderGenerateButton = () => {
    const button = el('generate');
    button.disabled = generating || !selectedFace;
    button.classList.toggle('generating', generating);
    button.lastChild.textContent = generating ? 'Gerando…' : (editingLayout ? 'Salvar alterações' : 'Gerar paginação');
  };
  const currentValues = () => {
    const payload = {};
    ids.forEach(id => payload[id] = decimalIds.includes(id)?parseDecimal(el(id).value):Number(el(id).value));
    payload.joint = payload.joint / 10;
    payload.pattern = document.querySelector('.pattern.active').dataset.pattern;
    payload.dry_joint = el('dry_joint').checked;
    return payload;
  };
  const send = () => {
    const payload = currentValues();
    if(decimalIds.some(id => !Number.isFinite(payload[id]))) return window.RevestPlanner.error('Use números válidos, por exemplo 15,5.');
    sketchup.update(JSON.stringify(payload));
  };
  const schedule = () => {
    clearTimeout(timer);
    const active=document.querySelector('.pattern.active');
    const editingDimension=document.activeElement===el('width')||document.activeElement===el('height');
    let delay=active&&active.dataset.pattern==='quartzito'?450:220;
    if(editingDimension) delay=selectedAreaM2>=25?750:450;
    timer=setTimeout(send,delay);
  };
  ids.forEach(id => el(id).addEventListener('input', () => { if(id==='stagger') el('staggerOutput').textContent=Math.round(el(id).value*100)+'%'; schedule(); }));
  el('dry_joint').addEventListener('change', () => { el('joint').disabled=el('dry_joint').checked; renderGroutAvailability(!el('dry_joint').checked); send(); });

  // Rejunte: caixa ao lado de Junta seca + tabela de cores com campos RGB.
  const GROUT_COLORS=[['Branco','#F4F3EF'],['Gelo','#E6E3DA'],['Cinza claro','#CFCFCB'],['Platina','#B9B5AD'],['Cinza','#9A9894'],['Cinza escuro','#6E6D6A'],['Grafite','#4A4A48'],['Preto','#262626'],
    ['Bege','#D8CBB3'],['Areia','#C9B79A'],['Camurça','#B59A7A'],['Caramelo','#9C7552'],['Marrom','#7A5C45'],['Tabaco','#5A4332'],['Terracota','#A45A3F'],['Verde musgo','#6F7B63']];
  let groutColor='#B9B5AD';
  let groutTimer=null;
  const toHex=v=>Math.max(0,Math.min(255,Math.round(Number(v)||0))).toString(16).padStart(2,'0').toUpperCase();
  const normalizeHex=value=>{ let hex=String(value||'').trim().replace(/^#?/,'#').toUpperCase(); if(/^#[0-9A-F]{3}$/.test(hex)) hex='#'+hex.slice(1).split('').map(c=>c+c).join(''); return /^#[0-9A-F]{6}$/.test(hex)?hex:null; };
  el('groutColors').innerHTML=GROUT_COLORS.map(([name,hex])=>`<button type="button" data-color="${hex}" title="${name} · ${hex}" style="background:${hex}"></button>`).join('');
  function renderGroutColor(hex, skip){
    groutColor=hex;
    el('groutSwatchColor').style.background=hex;
    const r=parseInt(hex.slice(1,3),16), g=parseInt(hex.slice(3,5),16), b=parseInt(hex.slice(5,7),16);
    if(skip!=='rgb'){ el('groutR').value=r; el('groutG').value=g; el('groutB').value=b; }
    if(skip!=='hex') el('groutHex').value=hex;
    el('groutPicker').value=hex.toLowerCase();
    el('groutColors').querySelectorAll('button').forEach(button=>button.classList.toggle('active',button.dataset.color===hex));
  }
  function renderGroutAvailability(available){
    el('groutControl').classList.toggle('unavailable',!available);
    el('grout').disabled=!available; el('groutSwatch').disabled=!available;
    el('groutControl').title=available?'':'Sem junta não há vão para o rejunte';
    if(!available) el('groutPalette').hidden=true;
  }
  const sendGrout=(delay=0)=>{ clearTimeout(groutTimer); groutTimer=setTimeout(()=>sketchup.updateGrout(JSON.stringify({grout:el('grout').checked,grout_color:groutColor})),delay); };
  const pickGroutColor=(hex,skip)=>{ renderGroutColor(hex,skip); el('grout').checked=true; sendGrout(250); };
  el('grout').addEventListener('change',()=>sendGrout());
  el('groutSwatch').onclick=event=>{
    event.stopPropagation();
    const palette=el('groutPalette');
    palette.hidden=!palette.hidden;
    if(palette.hidden) return;
    // Alinha à direita do botão; se a janela estiver estreita e faltar espaço, alinha à esquerda.
    palette.style.left=''; palette.style.right='';
    if(palette.getBoundingClientRect().left<8){ palette.style.left='0'; palette.style.right='auto'; }
  };
  el('groutPalette').addEventListener('click',event=>event.stopPropagation());
  el('groutColors').addEventListener('click',event=>{ const button=event.target.closest('button[data-color]'); if(button) pickGroutColor(button.dataset.color); });
  ['groutR','groutG','groutB'].forEach(id=>el(id).addEventListener('input',()=>pickGroutColor('#'+toHex(el('groutR').value)+toHex(el('groutG').value)+toHex(el('groutB').value),'rgb')));
  el('groutHex').addEventListener('input',()=>{ const hex=normalizeHex(el('groutHex').value); if(hex) pickGroutColor(hex,'hex'); });
  el('groutPicker').addEventListener('input',()=>pickGroutColor(el('groutPicker').value.toUpperCase()));
  document.addEventListener('click',()=>{ el('groutPalette').hidden=true; });
  renderGroutColor(groutColor);
  document.querySelectorAll('.pattern').forEach(button => button.addEventListener('click', () => {
    document.querySelectorAll('.pattern').forEach(item => item.classList.remove('active'));
    button.classList.add('active');
    if(button.dataset.pattern==='aligned') {
      el('width').value='60'; el('height').value='60';
    }
    if(button.dataset.pattern==='vertical') {
      el('width').value='10'; el('height').value='20';
    }
    if(button.dataset.pattern==='checkerboard') {
      el('width').value='20'; el('height').value='5';
    }
    if(button.dataset.pattern==='quartzito') {
      el('width').value='310'; el('height').value='195';
    }
    if(button.dataset.pattern==='brick') {
      el('width').value='25'; el('height').value='7'; el('stagger').value='0.5';
      el('staggerOutput').textContent='50%';
    }
    if(button.dataset.pattern==='chevron') {
      el('width').value='15,25'; el('height').value='22,5';
    }
    if(button.dataset.pattern==='herringbone') {
      el('width').value='7'; el('height').value='25';
    }
    schedule();
  }));
  el('pickFace').onclick = () => sketchup.pickFace();
  const permanent = new Set(['HEADER','NAV']);
  Array.from(document.querySelector('main').children).forEach(child => {
    if(!permanent.has(child.tagName) && child.id!=='presetPanel' && child.id!=='documentationPanel' && child.id!=='error') child.classList.add('home-view');
  });
  const showTab = tabName => {
    document.querySelectorAll('.tab').forEach(button => button.classList.toggle('active',button.dataset.tab===tabName));
    document.querySelectorAll('.home-view').forEach(item => item.hidden=tabName!=='home');
    el('presetPanel').hidden=tabName!=='presets';
    el('documentationPanel').hidden=tabName!=='documentation';
    if(tabName==='documentation') sketchup.requestDocumentation();
  };
  document.querySelectorAll('.tab').forEach(button => button.onclick=()=>showTab(button.dataset.tab));
  el('favoritePreset').onclick = () => {
    if(!editingPresetId) el('presetName').value='';
    updatePresetEditor(); showTab('presets'); el('presetName').focus();
  };
  el('cancelPresetEdit').onclick = () => { editingPresetId=null; el('presetName').value=''; updatePresetEditor(); };
  el('savePreset').onclick = async () => {
    const name=el('presetName').value.trim();
    if(!name) return window.RevestPlanner.error('Informe um nome para o preset.');
    const values=currentValues();
    if(decimalIds.some(id => !Number.isFinite(values[id]))) return window.RevestPlanner.error('Use números válidos antes de salvar.');
    const ok=await sketchup.savePreset(JSON.stringify({id:editingPresetId,name,values}));
    if(ok!==false){editingPresetId=null;el('presetName').value='';updatePresetEditor();}
  };
  el('chooseTextures').onclick = () => el('textureFiles').click();
  el('varyCombination').onclick = () => sketchup.varyCombination();
  el('textureFiles').onchange = async event => {
    const files=Array.from(event.target.files||[]);
    if(!files.length) return;
    const preview=el('texturePreview'); preview.innerHTML=''; preview.style.display='grid';
    files.forEach(file => {
      const img=document.createElement('img'); img.src=URL.createObjectURL(file); img.title=file.name;
      img.style.cssText='width:100%;aspect-ratio:1;object-fit:cover;border-radius:6px;border:1px solid #d8e0eb';
      preview.appendChild(img);
    });
    el('textureProgress').textContent='Preparando '+files.length+' imagens…';
    await sketchup.clearTextures();
    let imported=0;
    for(const file of files){
      const payload=await prepareTexture(file);
      const ok=await sketchup.importTexture(JSON.stringify(payload));
      if(ok!==false) imported++;
      el('textureProgress').textContent='Importando '+imported+' de '+files.length+'…';
    }
    await sketchup.finishTextures();
    el('textureProgress').textContent=imported+' imagens prontas para uso';
    event.target.value='';
  };
  el('pickAnchor').onclick = () => sketchup.pickAnchor();
  el('rotateInModel').onclick = () => sketchup.rotateInModel();
  el('centerLayout').onclick = () => sketchup.centerLayout();
  document.querySelectorAll('.angle-preset').forEach(button => button.onclick = () => {
    sketchup.update(JSON.stringify({rotation:Number(button.dataset.angle)}));
  });
  el('generate').onclick = () => {
    if(generating) return;
    generating = true;
    renderGenerateButton();
    requestAnimationFrame(() => setTimeout(() => sketchup.generate(), 50));
  };
  el('docQuantitative').onclick = () => sketchup.openSelectedReport();
  ['docStart','docDirection','docTag'].forEach(id => el(id).addEventListener('change', async () => {
    if(!documentationGroupId) return;
    const saved=await sketchup.updateDocumentation(JSON.stringify({group_id:documentationGroupId,indications:{start:el('docStart').checked,direction:el('docDirection').checked,tag:el('docTag').checked},arrow_count:documentationArrowCount,label:el('docName').value.trim()}));
    if(saved===false) sketchup.requestDocumentation();
  }));
  el('docName').addEventListener('input', () => {
    clearTimeout(documentationNameTimer);
    if(documentationGroupId) documentationNameTimer=setTimeout(() => sketchup.updateDocumentation(JSON.stringify({group_id:documentationGroupId,indications:{start:el('docStart').checked,direction:el('docDirection').checked,tag:el('docTag').checked},arrow_count:documentationArrowCount,label:el('docName').value.trim()})),450);
  });
  // Com 2 setas os dois espelhamentos já chegam a todas as posições; "Girar 90°" só aparece com 1 ou 3.
  function updateArrowButtons(){ el('docArrowRotate').style.display=documentationArrowCount===2?'none':''; }
  document.querySelectorAll('.arrow-model').forEach(button=>button.onclick=()=>{
    if(!documentationGroupId||!el('docDirection').checked) return;
    documentationArrowCount=Number(button.dataset.arrowCount);
    document.querySelectorAll('.arrow-model').forEach(item=>item.classList.toggle('active',item===button));
    updateArrowButtons();
    sketchup.updateDocumentation(JSON.stringify({group_id:documentationGroupId,indications:{start:el('docStart').checked,direction:true,tag:el('docTag').checked},arrow_count:documentationArrowCount,label:el('docName').value.trim()}));
  });
  const beginDocumentationPlacement=(mode,message)=>{el('docToolHint').textContent=message;sketchup.pickDocumentationPosition(mode);};
  el('docPickStart').onclick=()=>beginDocumentationPlacement('start','Clique na peça inicial dentro do modelo. Esc cancela.');
  el('docPickDirectionOrigin').onclick=()=>{sketchup.pickArrowOrigin(documentationGroupId||0);};
  el('docMoveTag').onclick=()=>beginDocumentationPlacement('tag','Clique no novo lugar da tag dentro do modelo. Esc cancela.');
  el('docTagSmaller').onclick=()=>sketchup.scaleTag(documentationGroupId||0,1/1.2);
  el('docTagBigger').onclick=()=>sketchup.scaleTag(documentationGroupId||0,1.2);
  el('docArrowRotate').onclick=()=>sketchup.rotateArrows(documentationGroupId||0,-90);
  el('docArrowFlipH').onclick=()=>sketchup.flipArrows(documentationGroupId||0,'h');
  el('docArrowFlipV').onclick=()=>sketchup.flipArrows(documentationGroupId||0,'v');
  el('docArrowSmaller').onclick=()=>sketchup.scaleArrows(documentationGroupId||0,1/1.2);
  el('docArrowBigger').onclick=()=>sketchup.scaleArrows(documentationGroupId||0,1.2);
  el('editLayoutButton').onclick = () => sketchup.editSelectedLayout();
  el('closeFinalReport').onclick = () => { el('finalReportModal').hidden=true; };
  el('finalReportModal').onclick = event => { if(event.target===el('finalReportModal')) el('finalReportModal').hidden=true; };
  el('finalWaste').addEventListener('input', updateFinalCalculations);
  el('piecesPerBox').addEventListener('input', updateFinalCalculations);
  el('finalName').addEventListener('input', updateFinalCalculations);
  el('finalExportPng').onclick = () => exportReportPng();
  el('finalExportLayout').onclick = () => { if(finalReport) sketchup.exportToLayout(JSON.stringify(Object.assign(finalExportData(),{scenes:selectedScenes()}))); };
  // Enquanto a ferramenta das setas está ativa, as teclas digitadas com o foco no painel
  // são repassadas para ela (o foco costuma ficar aqui depois de clicar em "Posicionar setas").
  let arrowToolOn=false;
  const arrowKeys={ArrowLeft:'left',ArrowRight:'right',ArrowUp:'up',ArrowDown:'down',Tab:'right',Escape:'escape'};
  document.addEventListener('keydown',event=>{
    if(!arrowToolOn) return;
    const tag=(event.target&&event.target.tagName)||'';
    if(tag==='INPUT'||tag==='TEXTAREA') return;
    const name=arrowKeys[event.key];
    if(!name) return;
    event.preventDefault();
    sketchup.arrowToolKey(name);
  });
  window.RevestPlanner = {
    arrowToolActive(active) { arrowToolOn=!!active; },
    documentationPrompt(message) {
      el('docToolHint').textContent=message||'Aproxime as setas do canto da peça para ajustá-las automaticamente. Se necessário, faça os demais ajustes com as ferramentas disponíveis.';
    },
    receive(data) {
      state = data.state;
      selectedFace = !!data.face.selected;
      editingLayout = !!data.editing_layout;
      selectedAreaM2=data.face&&data.face.selected?Number(data.face.area_m2)||0:0;
      ids.forEach(id => { if(document.activeElement !== el(id) && state[id] != null) el(id).value=decimalIds.includes(id)?formatDecimal(id==='joint'?state[id]*10:state[id]):state[id]; });
      document.querySelectorAll('.pattern').forEach(item => item.classList.toggle('active',item.dataset.pattern===state.pattern));
      el('dry_joint').checked=!!state.dry_joint; el('joint').disabled=!!state.dry_joint;
      if(data.grout){
        el('grout').checked=!!data.grout.enabled;
        const paletteOpen=!el('groutPalette').hidden;
        if(!paletteOpen||!groutTimer) renderGroutColor(normalizeHex(data.grout.color)||groutColor);
        renderGroutAvailability(!!data.grout.available);
      }
      el('staggerOutput').textContent=Math.round(state.stagger*100)+'%';
      el('staggerRow').style.display=state.pattern==='brick'?'grid':'none';
      const moduleMode=state.pattern==='quartzito';
      el('dimensionTitle').textContent=moduleMode?'Módulo e junta':'Peça e junta';
      el('widthLabel').textContent=moduleMode?'Largura do módulo':'Largura';
      el('heightLabel').textContent=moduleMode?'Altura do módulo':'Altura';
      el('faceStatus').textContent=data.face.selected?'Face selecionada':'Nenhuma face selecionada';
      el('faceArea').textContent=data.face.selected?formatArea(data.face.area_m2)+' m²':'';
      const textures=state.texture_paths||[];
      el('textureName').textContent=textures.length?textures.length+' imagens selecionadas':(state.pattern==='quartzito'?'Textura padrão Pedra orgânica':'JPG e PNG');
      el('varyCombination').disabled=!data.can_vary_combination;
      el('variationNumber').textContent=((data.texture_variation||1))+' de 4';
      const result=data.result;
      renderPresets(data.presets||[]);
      el('whole').textContent=result?result.whole_count+' un':'—'; el('cut').textContent=result?result.cut_count+' un':'—';
      el('previewArea').textContent=result?formatArea(result.area_total_m2)+' m²':'—';
      el('previewTotal').textContent=result?result.installed_count+' un':'—';
      renderGenerateButton();
      el('editLayoutButton').disabled=!data.selected_layout||!!data.editing_layout;
      el('editLayoutButton').lastChild.textContent=data.editing_layout?'Editando':'Editar paginação';
      el('pickAnchor').classList.toggle('active',!!data.anchor_mode);
      el('pickAnchor').querySelector('span:last-child').textContent=data.anchor_mode?'Clique no ponto dentro do modelo':'Escolher ponto inicial no modelo';
      el('rotateInModel').classList.toggle('active',!!data.rotation_mode);
      el('rotateInModel').querySelector('span:last-child').textContent=data.rotation_mode?'Mova o mouse e clique para confirmar':'Rotacionar no modelo';
      el('currentAngle').textContent=(Math.round((state.rotation||0)*10)/10)+'°';
      document.querySelectorAll('.angle-preset').forEach(button=>button.classList.toggle('active',Math.abs(Number(button.dataset.angle)-(state.rotation||0))<0.01));
      el('error').classList.remove('show');
      renderDocumentation(data.documentation);
    },
    error(message) { generating=false; renderGenerateButton(); el('error').textContent=message; el('error').classList.add('show'); },
    generationDone() { generating=false; renderGenerateButton(); },
    openFinalReport(report) {
      generating=false;
      renderGenerateButton();
      finalReport=report;
      renderSceneChoices(report.scenes||[]);
      el('finalName').value=report.name&&report.name!=='Revestimento'?report.name:'';
      el('finalWaste').value=formatDecimal(report.waste_percent||10);
      const boxExampleMigration='revest_box_example_placeholder_v1';
      const clearLegacyExample=Number(report.pieces_per_box)===3&&!localStorage.getItem(boxExampleMigration);
      el('piecesPerBox').value=!clearLegacyExample&&report.pieces_per_box>0?report.pieces_per_box:'';
      if(clearLegacyExample) localStorage.setItem(boxExampleMigration,'1');
      const names={aligned:'Horizontal',vertical:'Vertical',diagonal:'Diagonal',brick:'Tijolinho',checkerboard:'Damas',alternating:'Alternado',chevron:'Chevron',herringbone:'Espinha',quartzito:'Pedra orgânica'};
      report.pattern_name=names[report.pattern]||report.pattern;
      el('finalSpecification').textContent=formatDecimal(report.width)+' × '+formatDecimal(report.height)+' cm · Espessura: '+formatDecimal(report.thickness)+' mm · '+(report.dry_joint?'Junta seca':'Junta: '+formatDecimal(report.joint*10)+' mm')+' · Padrão: '+report.pattern_name+' · Rotação: '+formatDecimal(report.rotation)+'°';
      el('finalArea').textContent=formatArea(report.area_m2)+' m²';
      el('finalWhole').textContent=report.whole_count+' un'; el('finalCut').textContent=report.cut_count+' un'; el('finalTotal').textContent=report.total_count+' un';
      updateFinalCalculations();
      el('finalReportModal').hidden=false;
    },
    exportPngWithTexture(textureUrl) {
      renderReportPng(textureUrl||'');
    }
  };
  sketchup.ready();

  function updatePresetEditor(){
    el('savePreset').textContent=editingPresetId?'Atualizar preset':'Salvar novo';
    el('cancelPresetEdit').hidden=!editingPresetId;
  }

  function renderDocumentation(data){
    documentationGroupId=data&&data.group_id||null;
    el('documentationHint').hidden=!!data;
    el('documentationContent').hidden=!data;
    if(!data) return;
    const indications=data.indications||{};
    documentationArrowCount=Number(data.arrow_count)||2;
    el('docStart').checked=!!indications.start;
    el('docDirection').checked=!!indications.direction;
    el('docTag').checked=!!indications.tag;
    el('docPickStart').disabled=!indications.start;
    ['docPickDirectionOrigin','docArrowRotate','docArrowFlipH','docArrowFlipV','docArrowSmaller','docArrowBigger'].forEach(id=>el(id).disabled=!indications.direction);
    updateArrowButtons();
    document.querySelectorAll('.arrow-model').forEach(button=>{button.disabled=!indications.direction;button.classList.toggle('active',Number(button.dataset.arrowCount)===documentationArrowCount);});
    ['docMoveTag','docTagSmaller','docTagBigger'].forEach(id=>el(id).disabled=!indications.tag);
    if(document.activeElement!==el('docName')) el('docName').value=data.label||'';
  }

  function renderPresets(presets){
    const list=el('presetList'); list.innerHTML='';
    if(!presets.length){list.innerHTML='<div class="preset-empty">Nenhum preset salvo ainda.<br>Use o coração para adicionar seu primeiro revestimento.</div>';return;}
    presets.forEach(preset=>{
      const card=document.createElement('article'); card.className='preset-card';
      const joint=preset.dry_joint?'junta seca':formatDecimal(preset.joint*10)+' mm de junta';
      const patternNames={aligned:'Horizontal',vertical:'Vertical',diagonal:'Diagonal',brick:'Tijolinho',checkerboard:'Damas',alternating:'Alternado',chevron:'Chevron',herringbone:'Espinha',quartzito:'Pedra orgânica'};
      card.innerHTML='<div class="preset-card-head"><div><strong></strong><small></small></div><span>♡</span></div><div class="preset-actions"><button class="secondary load">Carregar</button><button class="secondary edit">Editar</button><button class="secondary danger remove">Excluir</button></div>';
      card.querySelector('strong').textContent=preset.name;
      card.querySelector('small').textContent=(patternNames[preset.pattern]||preset.pattern)+' · '+formatDecimal(preset.width)+' × '+formatDecimal(preset.height)+' cm · '+formatDecimal(preset.thickness)+' mm · '+joint+' · perda '+formatDecimal(preset.waste_percent)+'% · '+preset.texture_count+' textura(s)';
      card.querySelector('.load').onclick=async()=>{const ok=await sketchup.loadPreset(preset.id);if(ok!==false)showTab('home');};
      card.querySelector('.edit').onclick=async()=>{const ok=await sketchup.loadPreset(preset.id);if(ok!==false){editingPresetId=preset.id;el('presetName').value=preset.name;updatePresetEditor();showTab('home');}};
      card.querySelector('.remove').onclick=async()=>{if(confirm('Excluir o preset “'+preset.name+'” e suas cópias de textura?'))await sketchup.deletePreset(preset.id);};
      list.appendChild(card);
    });
  }

  function prepareTexture(file){
    return new Promise((resolve,reject)=>{
      const reader=new FileReader();
      reader.onerror=reject;
      reader.onload=()=>{
        const image=new Image();
        image.onerror=reject;
        image.onload=()=>{
          const tileWidth=parseDecimal(el('width').value), tileHeight=parseDecimal(el('height').value);
          const targetRatio=tileWidth>0&&tileHeight>0?tileWidth/tileHeight:image.width/image.height;
          const originalRatio=image.width/image.height;
          const originalMime=file.type==='image/png'?'image/png':'image/jpeg';
          const orientationDiffers=(targetRatio<1&&image.width>image.height)||(targetRatio>1&&image.width<image.height);
          const ratioError=Math.abs(Math.log(originalRatio/targetRatio));

          // Se a foto já corresponde à proporção e orientação da peça, envia
          // os pixels originais: sem redimensionar, recomprimir ou desfocar.
          if(!orientationDiffers&&ratioError<0.015&&(file.type==='image/png'||file.type==='image/jpeg')){
            resolve({name:file.name,mime:originalMime,data:reader.result});
            return;
          }

          let source=image,sourceWidth=image.width,sourceHeight=image.height;
          if(orientationDiffers){
            const oriented=document.createElement('canvas'); oriented.width=image.height; oriented.height=image.width;
            const orientedContext=oriented.getContext('2d'); orientedContext.translate(oriented.width/2,oriented.height/2); orientedContext.rotate(Math.PI/2); orientedContext.drawImage(image,-image.width/2,-image.height/2);
            source=oriented; sourceWidth=oriented.width; sourceHeight=oriented.height;
          }
          let sx=0,sy=0,sw=sourceWidth,sh=sourceHeight;
          const sourceRatio=sw/sh;
          if(sourceRatio>targetRatio){const nextWidth=sh*targetRatio;sx+=(sw-nextWidth)/2;sw=nextWidth;}
          else if(sourceRatio<targetRatio){const nextHeight=sw/targetRatio;sy+=(sh-nextHeight)/2;sh=nextHeight;}
          const max=4096;
          const scale=Math.min(1,max/Math.max(sw,sh));
          const canvasWidth=Math.max(1,Math.round(sw*scale));
          const canvasHeight=Math.max(1,Math.round(sh*scale));
          const canvas=document.createElement('canvas'); canvas.width=canvasWidth; canvas.height=canvasHeight;
          const context=canvas.getContext('2d'); context.imageSmoothingEnabled=true; context.imageSmoothingQuality='high'; context.fillStyle='#ffffff'; context.fillRect(0,0,canvas.width,canvas.height); context.drawImage(source,sx,sy,sw,sh,0,0,canvas.width,canvas.height);
          const outputMime=file.type==='image/png'?'image/png':'image/jpeg';
          resolve({name:file.name,mime:outputMime,data:canvas.toDataURL(outputMime,0.98)});
        };
        image.src=reader.result;
      };
      reader.readAsDataURL(file);
    });
  }

  function parseDecimal(value){
    return Number(String(value).trim().replace(/\s/g,'').replace(',','.'));
  }

  function formatDecimal(value){
    return String(value).replace('.',',');
  }

  function formatArea(value){
    return Number(value||0).toLocaleString('pt-BR',{minimumFractionDigits:2,maximumFractionDigits:2});
  }

  function formatPercent(value){
    return Number(value||0).toLocaleString('pt-BR',{maximumFractionDigits:2})+'%';
  }

  function updateFinalCalculations(){
    if(!finalReport) return;
    const waste=Math.max(0,parseDecimal(el('finalWaste').value)||0);
    const piecesPerBox=Math.max(0,Math.floor(parseDecimal(el('piecesPerBox').value)||0));
    const purchaseArea=finalReport.area_m2*(1+waste/100);
    const purchaseTotal=Math.ceil(finalReport.total_count*(1+waste/100));
    const areaPerBox=piecesPerBox*finalReport.piece_area_m2;
    const boxesNeeded=piecesPerBox?Math.ceil(purchaseTotal/piecesPerBox):0;
    const purchasedArea=boxesNeeded*areaPerBox;
    el('purchaseArea').textContent=formatArea(purchaseArea)+' m²'; el('purchaseTotal').textContent=purchaseTotal+' un';
    el('areaPerBox').textContent=piecesPerBox?formatArea(areaPerBox)+' m²':'—';
    el('boxesNeeded').textContent=piecesPerBox?boxesNeeded+' cx':'—'; el('purchasedArea').textContent=piecesPerBox?formatArea(purchasedArea)+' m²':'—';
    clearTimeout(reportSaveTimer);
    if(finalReport.group_id){
      reportSaveTimer=setTimeout(()=>sketchup.saveFinalReportState(JSON.stringify({group_id:finalReport.group_id,name:el('finalName').value.trim()||'Revestimento',waste_percent:waste,pieces_per_box:piecesPerBox})),250);
    }
  }

  // Cenas do arquivo para exportar junto com o quantitativo (as marcadas ficam lembradas na sessão).
  // Cenas do arquivo para exportar junto com o quantitativo: lista suspensa com caixas de marcar,
  // "Selecionar todas" e um resumo "2 de 5 selecionadas" no botão. As marcadas ficam lembradas na sessão.
  const chosenScenes=new Set();
  let availableScenes=[];
  function updateSceneSummary(){
    const count=availableScenes.filter(name=>chosenScenes.has(name)).length;
    el('finalScenesSummary').textContent=!availableScenes.length?'Nenhuma cena no arquivo':
      count===0?'Nenhuma cena selecionada':count===1&&availableScenes.length>1?availableScenes.find(name=>chosenScenes.has(name)):
      count+' de '+availableScenes.length+' selecionadas';
    const all=el('finalScenes').querySelector('input[data-all]');
    if(all){ all.checked=count===availableScenes.length; all.indeterminate=count>0&&count<availableScenes.length; }
  }
  function renderSceneChoices(scenes){
    availableScenes=scenes;
    const box=el('finalScenes');
    box.innerHTML='';
    if(!scenes.length){
      box.innerHTML='<span class="empty">Este arquivo não tem cenas. Crie cenas no SketchUp (Janela › Cenas) para exportá-las.</span>';
      updateSceneSummary();
      return;
    }
    const option=(text,checked,onchange,extraClass,isAll)=>{
      const label=document.createElement('label');
      if(extraClass) label.className=extraClass;
      const input=document.createElement('input');
      input.type='checkbox'; input.checked=checked; input.onchange=()=>onchange(input.checked);
      if(isAll) input.dataset.all='1';
      label.append(input,document.createTextNode(text));
      box.append(label);
      return input;
    };
    option('Selecionar todas',false,checked=>{
      scenes.forEach(name=>checked?chosenScenes.add(name):chosenScenes.delete(name));
      box.querySelectorAll('input[data-scene]').forEach(input=>input.checked=checked);
      updateSceneSummary();
    },'all',true);
    scenes.forEach(name=>{
      const input=option(name,chosenScenes.has(name),checked=>{
        if(checked) chosenScenes.add(name); else chosenScenes.delete(name);
        updateSceneSummary();
      });
      input.dataset.scene=name;
    });
    updateSceneSummary();
  }
  function selectedScenes(){ return availableScenes.filter(name=>chosenScenes.has(name)); }
  el('finalScenesToggle').onclick=event=>{
    event.stopPropagation();
    const list=el('finalScenes');
    list.hidden=!list.hidden;
    list.parentElement.classList.toggle('open',!list.hidden);
  };
  el('finalScenes').addEventListener('click',event=>event.stopPropagation());
  document.addEventListener('click',()=>{ el('finalScenes').hidden=true; el('finalScenes').parentElement.classList.remove('open'); });

  function finalExportData(){
    const waste=Math.max(0,parseDecimal(el('finalWaste').value)||0), piecesPerBox=Math.max(0,Math.floor(parseDecimal(el('piecesPerBox').value)||0));
    const purchaseArea=finalReport.area_m2*(1+waste/100), purchaseTotal=Math.ceil(finalReport.total_count*(1+waste/100));
    const areaPerBox=piecesPerBox*finalReport.piece_area_m2, boxesNeeded=piecesPerBox?Math.ceil(purchaseTotal/piecesPerBox):0;
    return {group_id:finalReport.group_id,name:el('finalName').value.trim()||'Revestimento',pattern_name:finalReport.pattern_name,dimensions:formatDecimal(finalReport.width)+' × '+formatDecimal(finalReport.height),thickness:formatDecimal(finalReport.thickness),joint:finalReport.dry_joint?'Junta seca':formatDecimal(finalReport.joint*10)+' mm',area:formatArea(finalReport.area_m2),whole:finalReport.whole_count,cut:finalReport.cut_count,total:finalReport.total_count,waste:formatDecimal(waste),purchase_area:formatArea(purchaseArea),purchase_total:purchaseTotal,pieces_per_box:piecesPerBox||'',area_per_box:piecesPerBox?formatArea(areaPerBox):'',boxes_needed:boxesNeeded||'',purchased_area:piecesPerBox?formatArea(boxesNeeded*areaPerBox):''};
  }

  function exportReportPng(){
    if(!finalReport) return window.RevestPlanner.error('Gere a paginação antes de exportar.');
    sketchup.requestReportTexture(finalReport.group_id);
  }

  async function renderReportPng(textureUrl){
    const result=finalExportData();
    const canvas=document.createElement('canvas'); canvas.width=1600; canvas.height=1000;
    const ctx=canvas.getContext('2d');
    ctx.fillStyle='#ffffff'; ctx.fillRect(0,0,canvas.width,canvas.height);
    ctx.textBaseline='middle'; ctx.fillStyle='#202428';
    ctx.font='700 13px Segoe UI, Arial'; ctx.fillText('R E V E S T I M E N T O',100,72);
    ctx.strokeStyle='#dadddf'; ctx.lineWidth=1; ctx.beginPath(); ctx.moveTo(330,72); ctx.lineTo(1110,72); ctx.stroke();
    ctx.fillStyle='#70757d'; ctx.font='400 12px Segoe UI, Arial'; ctx.fillText('D E T A L H A M E N T O   E X E C U T I V O',1240,72);
    ctx.fillStyle='#202428'; ctx.font='700 48px Segoe UI, Arial'; ctx.fillText('QUANTITATIVO',100,145);

    const rows=[
      ['REVESTIMENTO',result.name],['DIMENSÃO DA PEÇA',result.dimensions+' cm'],['ESPESSURA',result.thickness+' mm'],
      ['JUNTA',result.joint],['PADRÃO DE PAGINAÇÃO',result.pattern_name],['ÁREA REVESTIDA',result.area+' m²'],
      ['PERCENTUAL DE PERDA',result.waste+'%'],['QUANTIDADE DE PEÇAS',result.purchase_total+' un'],
      ['PEÇAS POR CAIXA',result.pieces_per_box?result.pieces_per_box+' un':'—'],['CAIXAS PARA COMPRA',result.boxes_needed?result.boxes_needed+' cx':'—'],
      ['ÁREA TOTAL COMPRADA',result.purchased_area?result.purchased_area+' m²':'—']
    ];
    const tableX=100,tableY=220,tableW=940,labelW=380,rowH=60;
    rows.forEach((row,index)=>{
      const y=tableY+index*rowH;
      if(index%2===0){ctx.fillStyle='#f6f6f6';ctx.fillRect(tableX,y,tableW,rowH);}
      ctx.strokeStyle='#dadddf';ctx.lineWidth=1;ctx.beginPath();ctx.moveTo(tableX,y+rowH);ctx.lineTo(tableX+tableW,y+rowH);ctx.stroke();
      ctx.fillStyle='#202428';ctx.font='700 16px Segoe UI, Arial';ctx.fillText(row[0],tableX+18,y+rowH/2);
      ctx.font='400 17px Segoe UI, Arial';ctx.fillText(String(row[1]||'—'),tableX+labelW+18,y+rowH/2);
    });
    ctx.strokeStyle='#8d9297';ctx.beginPath();ctx.moveTo(tableX+labelW,tableY);ctx.lineTo(tableX+labelW,tableY+rows.length*rowH);ctx.stroke();

    if(textureUrl){
      try{
        const image=await loadCanvasImage(textureUrl);
        drawImageCover(ctx,image,1120,240,370,420);
      }catch(_error){}
    }
    ctx.fillStyle='#CED629';ctx.fillRect(1120,700,62,4);
    ctx.fillStyle='#202428';ctx.font='700 17px Segoe UI, Arial';drawWrappedText(ctx,result.name.toUpperCase(),1120,735,370,21);
    ctx.fillStyle='#70757d';ctx.font='400 13px Segoe UI, Arial';ctx.fillText('FABRICANTE',1120,790);
    sketchup.exportPng(canvas.toDataURL('image/png'));
  }

  function loadCanvasImage(source){
    return new Promise((resolve,reject)=>{const image=new Image();image.onload=()=>resolve(image);image.onerror=reject;image.src=source;});
  }

  function drawImageCover(ctx,image,x,y,width,height){
    const scale=Math.max(width/image.width,height/image.height),sourceW=width/scale,sourceH=height/scale;
    ctx.drawImage(image,(image.width-sourceW)/2,(image.height-sourceH)/2,sourceW,sourceH,x,y,width,height);
  }

  function drawWrappedText(ctx,text,x,y,maxWidth,lineHeight){
    const words=text.split(/\s+/);let line='';
    words.forEach(word=>{const test=line?line+' '+word:word;if(ctx.measureText(test).width>maxWidth&&line){ctx.fillText(line,x,y);line=word;y+=lineHeight;}else line=test;});
    if(line)ctx.fillText(line,x,y);
  }
})();
