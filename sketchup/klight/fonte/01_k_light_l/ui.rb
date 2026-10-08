module KahDetalha
  module KLight

    module Dialog

      HTML = <<~HTML
        <!DOCTYPE html>
        <html lang="pt-BR" class="{{THEME_CLASS}}">
        <head>
        <meta charset="UTF-8">
        <style>
          *{box-sizing:border-box;margin:0;padding:0}
          html{background:#111}
          body{font-family:'Segoe UI',sans-serif;background:#111;color:#e8e8e8;
               padding:12px 14px 18px;font-size:13px;overflow-x:hidden;overflow-y:auto;
               scrollbar-width:none;-ms-overflow-style:none}
          body::-webkit-scrollbar{width:0;height:0;background:transparent}
          h2{font-size:13px;color:#CED629;margin-bottom:10px;font-weight:700;
             letter-spacing:.06em;text-transform:uppercase}
          .beta-tag{font-family:'Segoe UI',sans-serif;font-size:8px;font-weight:600;
             color:#fff;background:#1e1e1e;border:1px solid #333;border-radius:3px;
             padding:2px 5px;letter-spacing:.05em;vertical-align:middle;margin-left:2px;
             text-transform:none}
          .lbl{display:block;font-size:10px;color:#fff;text-transform:uppercase;
               letter-spacing:.07em;margin-bottom:3px;margin-top:10px}
          input[type=number]{background:#1e1e1e;border:1px solid #2a2a2a;
            color:#e8e8e8;padding:5px 8px;border-radius:4px;font-size:13px;width:64px}
          input[type=range]{accent-color:#CED629;cursor:pointer;flex:1;
            -webkit-appearance:none;appearance:none;height:4px;background:#2a2a2a;
            border-radius:2px;outline:none}
          input[type=range]::-webkit-slider-runnable-track{height:4px;background:#2a2a2a;
            border-radius:2px}
          input[type=range]::-webkit-slider-thumb{-webkit-appearance:none;appearance:none;
            width:14px;height:14px;border-radius:50%;background:#CED629;border:none;
            margin-top:-5px;cursor:pointer;box-shadow:0 0 0 2px rgba(206,214,41,.25)}
          input[type=range]::-moz-range-track{height:4px;background:#2a2a2a;border-radius:2px}
          input[type=range]::-moz-range-progress{height:4px;background:#CED629;border-radius:2px}
          input[type=range]::-moz-range-thumb{width:14px;height:14px;border-radius:50%;
            background:#CED629;border:none;cursor:pointer}
          input[type=range]::-ms-track{height:4px;background:transparent;border-color:transparent;
            color:transparent}
          input[type=range]::-ms-fill-lower{background:#CED629;border-radius:2px}
          input[type=range]::-ms-fill-upper{background:#2a2a2a;border-radius:2px}
          input[type=range]::-ms-thumb{width:14px;height:14px;border-radius:50%;
            background:#CED629;border:none;cursor:pointer}
          input[type=color]{border:2px solid #333;background:#1e1e1e;width:36px;
            height:28px;cursor:pointer;border-radius:4px;padding:1px;vertical-align:middle}
          .val{color:#CED629;font-size:11px;margin-left:4px}
          .slider-row{display:flex;align-items:center;gap:8px;margin-top:3px}

          /* presets cor */
          .presets{display:grid;grid-template-columns:1fr 1fr 1fr 1fr;gap:5px;margin-top:4px}
          .pbtn{padding:7px 3px;border:1px solid #2a2a2a;border-radius:4px;
            background:#1a1a1a;color:#fff;font-size:11px;cursor:pointer;
            text-align:center;transition:all .12s}
          .pbtn:hover{border-color:#555;color:#fff}
          .pbtn.active{background:#CED629;color:#111;border-color:#CED629;font-weight:700;
            box-shadow:0 0 9px rgba(206,214,41,.55)}

          /* largura/queda do halo (backlight): travado na edição quando as
             faces originais do letreiro não foram reencontradas */
          #halo-style-section.locked input{opacity:.35;pointer-events:none}
          #halo-style-section.locked .hint{opacity:.6}

          /* direção da luz */
          .dir-row{display:grid;grid-template-columns:1fr 1fr;gap:6px;margin-top:4px}
          .dir-separator{height:1px;background:#2a2a2a;margin:8px 0}
          .dbtn,.vbtn{padding:9px 4px;border:1px solid #2a2a2a;border-radius:5px;
            background:#1a1a1a;color:#fff;font-size:11px;cursor:pointer;
            text-align:center;line-height:1.4;transition:all .12s}
          .dbtn:hover,.vbtn:hover{border-color:#555;color:#fff}
          .dbtn.active{background:#2a3a1a;color:#CED629;border-color:#CED629;
            box-shadow:0 0 8px rgba(206,214,41,.35)}
          .vbtn.active{background:#1a2a3a;color:#7fc8ff;border-color:#7fc8ff;
            box-shadow:0 0 8px rgba(127,200,255,.35)}
          .dbtn .icon,.vbtn .icon{font-size:18px;display:block}

          canvas{width:100%;height:34px;border-radius:5px;display:block;
                 border:1px solid #1e1e1e;margin-top:4px;margin-bottom:8px;
                 transition:box-shadow .18s ease, border-color .18s ease;
                 background-size:200% 100%;background-position:0 0}
          canvas.live{box-shadow:0 0 0 1px rgba(206,214,41,.5),0 0 10px rgba(206,214,41,.45);
                      border-color:#CED629}
          canvas.pending{border-color:#333;
            background-image:linear-gradient(90deg,#161616 0%,#232323 20%,#161616 40%);
            animation:shimmer 1s linear infinite}
          @keyframes shimmer{from{background-position:0 0}to{background-position:-200% 0}}

          .btn-apply{width:100%;padding:10px;background:#CED629;color:#111;border:none;
            border-radius:5px;font-size:13px;font-weight:700;cursor:pointer;margin-top:10px}
          .btn-apply:hover{background:#d8e030}
          .btn-secondary{width:100%;padding:8px;background:#202020;color:#CED629;
            border:1px solid #4a4a32;border-radius:5px;font-size:11px;font-weight:700;
            cursor:pointer;margin-top:7px}
          .btn-secondary:hover,.btn-secondary.active{background:#2a3018;border-color:#CED629}
          .btn-cancel{width:100%;padding:7px;background:transparent;color:#fff;
            border:none;font-size:11px;cursor:pointer;margin-top:3px;opacity:.55}
          .btn-cancel:hover{opacity:1}
          .section{border:1px solid #1a1a1a;border-radius:5px;padding:8px;margin-top:8px}
          .stitle{font-size:9px;color:#fff;text-transform:uppercase;
                  letter-spacing:.08em;margin-bottom:7px;opacity:.7}
          .rgb-row{display:flex;align-items:center;gap:8px;margin-top:7px}
          .rgb-row.rgb-hidden{display:none}

          /* toggle switch LED/SPOT/BACKLIGHT */
          .toggle-track{position:relative;display:flex;background:#1a1a1a;
            border:1px solid #2a2a2a;border-radius:20px;padding:3px;margin-bottom:14px;
            cursor:pointer;user-select:none}
          .toggle-thumb{position:absolute;top:3px;left:3px;width:calc(33.333% - 3px);
            height:calc(100% - 6px);background:#CED629;border-radius:17px;
            transition:transform .22s cubic-bezier(.4,0,.2,1);
            box-shadow:0 0 10px rgba(206,214,41,.5)}
          .toggle-track.on-spot .toggle-thumb{transform:translateX(100%)}
          .toggle-track.on-backlight .toggle-thumb{transform:translateX(200%)}
          .toggle-track.no-anim .toggle-thumb,
          .toggle-track.no-anim .toggle-label{transition:none !important}
          .toggle-label{position:relative;z-index:1;flex:1;text-align:center;
            padding:7px 4px;font-size:11px;font-weight:700;text-transform:uppercase;
            letter-spacing:.06em;color:#fff;opacity:.55;transition:color .18s ease, opacity .18s ease}
          .toggle-label.active{color:#111;opacity:1}
          .panel{display:none}
          .panel.active{display:block}
          .hint{font-size:10px;color:#fff;opacity:.7;line-height:1.5;margin:8px 0}

          /* K.Light UI 2.0 — linguagem visual da referência */
          html{background:#090a0a}
          body{font-family:'Segoe UI',Arial,sans-serif;background:
            radial-gradient(circle at 18% 0%,rgba(216,229,22,.035),transparent 32%),#090a0a;
            color:#f0f0f0;padding:20px 22px 24px;font-size:14px}
          .brand{display:flex;align-items:center;gap:14px;margin:0 0 18px;padding:2px 2px 0}
          .brand img{width:52px;height:52px;object-fit:contain;filter:brightness(0) saturate(100%) invert(85%) sepia(94%) saturate(1017%) hue-rotate(7deg) brightness(99%)}
          .brand-name{font-size:28px;line-height:1;color:#dce500;font-weight:800;letter-spacing:.06em;text-shadow:0 0 14px rgba(220,229,0,.22)}
          .brand-sub{font-size:11px;color:#d6d6d6;letter-spacing:.16em;text-transform:uppercase;margin-top:7px}
          .beta-tag{font-size:7px;vertical-align:top;margin-left:6px;background:#171717;border-color:#393939;color:#bbb}
          .toggle-track{height:104px;border-radius:10px;padding:0;margin-bottom:16px;background:linear-gradient(145deg,#0b0c0c,#111);
            border:1px solid #343636;box-shadow:inset 0 0 20px rgba(255,255,255,.012);overflow:hidden}
          .toggle-thumb{display:none}
          .toggle-label{display:flex;flex-direction:column;align-items:center;justify-content:center;gap:7px;padding:10px 6px;
            color:#ddd;opacity:.72;font-size:13px;font-weight:500;letter-spacing:.02em;border:1px solid transparent;border-radius:9px;margin:-1px;transition:all .16s}
          .toggle-label img{width:42px;height:42px;object-fit:contain;filter:invert(82%);opacity:.8;transition:all .16s}
          .toggle-label.active{color:#e5ec00;opacity:1;background:radial-gradient(circle at 50% 45%,rgba(220,229,0,.11),rgba(220,229,0,.025) 55%,transparent 75%);
            border-color:#dce500;box-shadow:inset 0 0 22px rgba(220,229,0,.055),0 0 12px rgba(220,229,0,.08)}
          .toggle-label.active img{filter:brightness(0) saturate(100%) invert(85%) sepia(94%) saturate(1017%) hue-rotate(7deg) brightness(99%);opacity:1}
          .panel.active{display:block;animation:panelIn .16s ease-out}@keyframes panelIn{from{opacity:.35;transform:translateY(3px)}to{opacity:1;transform:none}}
          .section{border:1px solid #303232;border-radius:10px;padding:15px;margin-top:13px;background:linear-gradient(145deg,#0b0c0c,#101111);box-shadow:inset 0 0 18px rgba(255,255,255,.01)}
          .stitle,.lbl{font-size:11px;color:#ececec;letter-spacing:.1em;font-weight:500}
          .lbl{margin-top:15px;margin-bottom:7px}.stitle{margin-bottom:12px;opacity:1}
          .presets{gap:0;margin-top:0;border:1px solid #3a3b3b;border-radius:8px;overflow:hidden}
          .pbtn{padding:12px 5px;border:0;border-right:1px solid #343535;border-radius:0;background:#101111;color:#e7e7e7;font-size:13px}
          .pbtn:last-child{border-right:0}.pbtn:hover{background:#171818}.pbtn.active{background:linear-gradient(135deg,#f0ed00,#cbd600);color:#080808;border-color:#dce500;box-shadow:inset 0 0 16px rgba(255,255,255,.24),0 0 16px rgba(220,229,0,.14)}
          .slider-row{gap:12px;margin-top:4px;padding:8px 0 3px}
          input[type=number]{background:#111212;border:1px solid #343636;color:#f1f1f1;padding:9px 10px;border-radius:8px;font-size:14px;width:76px;text-align:center}
          input[type=range]{height:5px;background:#2b2c2c;border-radius:5px}
          input[type=range]::-webkit-slider-runnable-track{height:5px;background:#2b2c2c;border-radius:5px}
          input[type=range]::-webkit-slider-thumb{width:17px;height:17px;margin-top:-6px;background:#dce500;border:1px solid #f4ff00;box-shadow:0 0 10px rgba(220,229,0,.38)}
          .val{font-size:12px;color:#dce500;font-weight:600}
          .dir-row{gap:8px;margin-top:8px}.dir-separator{display:none}
          .dbtn,.vbtn{padding:14px 8px;border:1px solid #303232;border-radius:8px;background:#101111;font-size:13px;color:#eee}
          .dbtn .icon,.vbtn .icon{font-size:24px;margin-bottom:3px}.dbtn.active{color:#e5ec00;border-color:#dce500;background:rgba(220,229,0,.07);box-shadow:inset 0 0 18px rgba(220,229,0,.04)}
          .vbtn.active{color:#70d5ff;border-color:#69cdf5;background:rgba(60,180,235,.055);box-shadow:inset 0 0 18px rgba(60,180,235,.04)}
          canvas{height:62px;border:1px solid #292b2b;border-radius:9px;margin-top:8px;margin-bottom:12px;background:#0b0c0c;box-shadow:inset 0 0 22px #050505}
          .hint{font-size:11px;color:#c9c9c9;opacity:.78;line-height:1.55;margin:11px 1px}
          .btn-apply{padding:15px;border-radius:8px;font-size:16px;margin-top:15px;background:linear-gradient(135deg,#eee900,#c8d300);box-shadow:inset 0 0 18px rgba(255,255,255,.26),0 0 15px rgba(220,229,0,.13)}
          .btn-apply:hover{background:linear-gradient(135deg,#f7f300,#dce500)}
          .btn-secondary{padding:11px;border-radius:7px;background:#111212;border-color:#44462e;font-size:12px}
          .btn-cancel{padding:12px;font-size:12px;color:#ddd;opacity:.68}
          .rgb-row{padding:9px;border-top:1px solid #292a2a;margin-top:10px}input[type=color]{width:44px;height:34px;border-radius:7px}
          .control-grid{display:grid;grid-template-columns:1fr 1fr;gap:10px;margin-top:12px}
          .control-card{border:1px solid #303232;border-radius:10px;padding:13px 14px 11px;background:linear-gradient(145deg,#0b0c0c,#101111);min-height:96px}
          .control-card .lbl{margin-top:0;min-height:28px;display:flex;align-items:center;justify-content:space-between}
          .control-card .slider-row{padding-top:8px}

          /* Escala compacta para uso como paleta lateral do SketchUp */
          body{padding:10px 12px 12px;font-size:12px;overflow-y:auto;scrollbar-width:thin;scrollbar-color:#3a3c3c transparent}
          body::-webkit-scrollbar{width:8px}body::-webkit-scrollbar-thumb{background:#3a3c3c;border-radius:4px}
          .brand{gap:10px;margin-bottom:11px}.brand img{width:38px;height:38px}
          .brand-name{font-size:21px}.brand-sub{font-size:8px;margin-top:5px}.beta-tag{font-size:6px}
          .toggle-track{height:78px;margin-bottom:11px}.toggle-label{gap:3px;padding:6px 4px;font-size:10px}
          .toggle-label img{width:31px;height:31px}
          .section{padding:10px;margin-top:9px;border-radius:8px}.stitle,.lbl{font-size:9px}.stitle{margin-bottom:8px}.lbl{margin-top:10px;margin-bottom:4px}
          .pbtn{padding:8px 3px;font-size:12px}.control-grid{gap:7px;margin-top:9px}
          .control-card{padding:9px 10px 7px;min-height:72px;border-radius:8px}.control-card .lbl{min-height:20px}.control-card .slider-row{padding-top:3px}
          .slider-row{gap:8px;padding:4px 0 2px}input[type=number]{padding:6px 7px;border-radius:6px;font-size:11px;width:62px}
          input[type=range]::-webkit-slider-thumb{width:14px;height:14px;margin-top:-5px}.val{font-size:10px}
          .dir-row{gap:6px;margin-top:6px}.dbtn,.vbtn{padding:9px 5px;font-size:10px}.dbtn .icon,.vbtn .icon{font-size:18px;margin-bottom:1px}
          canvas{height:44px;margin-top:5px;margin-bottom:8px;border-radius:7px}.hint{font-size:9px;margin:7px 1px}
          #cv_c{height:58px}#cv_s{height:88px}#cv_b{height:104px}
          .btn-apply{padding:11px;font-size:13px;margin-top:10px}.btn-secondary{padding:8px;font-size:10px;margin-top:5px}.btn-cancel{padding:8px;font-size:10px}
          .brand img{width:30px;height:30px}.brand-name{font-size:19px}.brand-sub{font-size:7px}
          .toggle-track{height:58px}.toggle-label{font-size:9px;gap:1px}.toggle-label img{width:21px;height:21px}
          .section{padding:8px}.control-card{min-height:58px;padding:7px 9px 5px}.control-card .lbl{min-height:16px}
          #cv_c{height:44px}#cv_s{height:64px}#cv_b{height:78px}#spot-hint{display:none!important}
          .spot-actions{border:1px solid #303232;border-radius:8px;padding:8px;margin-top:8px;background:linear-gradient(145deg,#0b0c0c,#101111)}
          .spot-actions .stitle{margin:0 0 7px}.spot-action-main,.spot-action-small{display:flex;align-items:center;text-align:left;background:#101111;color:#e8e8e8;border:1px solid #686b20;border-radius:7px;cursor:pointer}
          .spot-action-main{width:100%;padding:9px 12px;gap:12px}.spot-action-main:hover,.spot-action-small:hover,.spot-action-main.active,.spot-action-small.active{border-color:#dce500;background:rgba(220,229,0,.045)}
          .spot-action-copy{display:flex;flex-direction:column;gap:2px;font-size:11px;text-transform:uppercase;letter-spacing:.06em}.spot-action-copy small{font-size:8px;text-transform:none;letter-spacing:.02em;color:#aaa;font-weight:400}
          .spot-action-grid{display:grid;grid-template-columns:1fr 1fr;gap:6px;margin-top:6px}.spot-action-small{justify-content:center;gap:9px;padding:9px 6px;font-size:9px;text-transform:uppercase;letter-spacing:.04em}
          [data-tooltip]{position:relative}
          [data-tooltip]:after{content:attr(data-tooltip);position:absolute;z-index:200;left:50%;bottom:calc(100% + 7px);transform:translateX(-50%);width:220px;box-sizing:border-box;padding:7px 9px;border:1px solid #555;border-radius:5px;background:#24262b;color:#f3f3f3;font:10px/1.35 Arial,sans-serif;text-align:left;text-transform:none;letter-spacing:0;white-space:normal;overflow-wrap:break-word;pointer-events:none;opacity:0;visibility:hidden;transition:opacity .12s}
          [data-tooltip]:hover:after,[data-tooltip]:focus-visible:after{opacity:1;visibility:visible}
          .spot-action-small[data-tooltip]:after{left:0;right:auto;transform:none}
          .spot-action-small[data-tooltip]:last-child:after{left:auto;right:0}
          .action-icon{position:relative;display:inline-block;width:25px;height:25px;flex:0 0 25px;color:#dce500}
          .target-icon{border:2px solid currentColor;border-radius:50%}.target-icon:before,.target-icon:after{content:'';position:absolute;background:currentColor}.target-icon:before{left:10px;top:-5px;width:2px;height:31px}.target-icon:after{left:-5px;top:10px;width:31px;height:2px}.target-icon i{position:absolute;width:5px;height:5px;border:1px solid currentColor;border-radius:50%;left:8px;top:8px}
          .invert-icon:before{content:'↕';font-size:25px;line-height:23px;font-family:Arial,sans-serif}
          .replicate-icon:before,.replicate-icon:after{content:'';position:absolute;width:13px;height:13px;border:2px solid currentColor;border-radius:2px}.replicate-icon:before{left:3px;top:7px}.replicate-icon:after{left:9px;top:2px;background:#101111}
          .target-icon:before{left:10px;top:-5px;width:2px;height:6px;box-shadow:0 29px 0 currentColor}
          .target-icon:after{left:-5px;top:10px;width:6px;height:2px;box-shadow:29px 0 0 currentColor}
          input[type=color]{width:30px;height:24px;padding:0}
          /* Botão de tema (lua) — alterna fundo preto / cinza */
          .brand{position:relative}
          .theme-btn{position:absolute;top:0;right:0;width:26px;height:26px;display:grid;place-items:center;
            border:1px solid #343636;border-radius:7px;background:#101111;color:#dce500;cursor:pointer;padding:0}
          .theme-btn:hover{border-color:#dce500}
          .theme-btn svg{width:15px;height:15px;fill:none;stroke:currentColor;stroke-width:2;stroke-linejoin:round}

          /* Tema cinza — mesmo cinza de fundo do REVEST (#f2f3f0), cartões brancos */
          html.theme-gray,body.theme-gray{background:#f2f3f0;color:#202428}
          .theme-gray .theme-btn{background:#fff;border-color:#dbddda;color:#202428}
          .theme-gray .theme-btn:hover{border-color:#CED629;background:#fafbe9}
          .theme-gray .theme-btn svg{fill:#202428}
          .theme-gray .brand img{filter:brightness(0) saturate(100%) invert(12%)}
          .theme-gray .brand-name{color:#202428;text-shadow:none}
          .theme-gray .brand-sub{color:#596067}
          .theme-gray .beta-tag{background:#fff;border-color:#dbddda;color:#545a61}
          .theme-gray .stitle,.theme-gray .lbl{color:#3d4247}
          .theme-gray .hint{color:#545a61;opacity:1}
          .theme-gray .val{color:#6f7600}
          .theme-gray .section,.theme-gray .control-card,.theme-gray .spot-actions{background:#fff;border-color:#e6e7e4;
            box-shadow:0 2px 10px rgba(31,37,41,.04)}
          .theme-gray .toggle-track{background:#e9eae7;border-color:#e2e4e1;box-shadow:none}
          .theme-gray .toggle-label{color:#545a61;opacity:1}
          .theme-gray .toggle-label img{filter:brightness(0) saturate(100%) invert(30%);opacity:.75}
          .theme-gray .toggle-label.active{color:#202428;background:#fff;border-color:#CED629;box-shadow:inset 0 -3px 0 #CED629}
          .theme-gray .toggle-label.active img{filter:brightness(0) saturate(100%) invert(12%);opacity:1}
          .theme-gray .presets{border-color:#dfe1de}
          .theme-gray .pbtn{background:#fff;color:#202428;border-right-color:#e2e4e1}
          .theme-gray .pbtn:hover{background:#f7f8f5}
          .theme-gray .pbtn.active{background:#CED629;color:#202428;border-color:#CED629;box-shadow:none}
          .theme-gray .rgb-row{border-top-color:#e2e4e1}
          .theme-gray .rgb-row span{color:#202428!important}
          .theme-gray input[type=number]{background:#f7f8f6;border-color:#e0e2df;color:#202428}
          .theme-gray input[type=color]{background:#fff;border-color:#dfe1de}
          .theme-gray input[type=range],
          .theme-gray input[type=range]::-webkit-slider-runnable-track{background:#dfe1de}
          .theme-gray input[type=range]::-webkit-slider-thumb{background:#CED629;border-color:#b6bf0b;box-shadow:none}
          .theme-gray .dbtn,.theme-gray .vbtn{background:#fff;border-color:#dfe1de;color:#202428}
          .theme-gray .dbtn:hover,.theme-gray .vbtn:hover{border-color:#c4ca31}
          .theme-gray .dbtn.active{color:#202428;border-color:#b9c10e;background:#fafbe8;box-shadow:inset 0 0 0 1px #e7eb8a}
          .theme-gray .vbtn.active{color:#1d6f96;border-color:#69b8de;background:#eef8fd;box-shadow:none}
          .theme-gray canvas{border-color:#dfe1de}
          .theme-gray .btn-apply{background:#CED629;color:#202428;box-shadow:none}
          .theme-gray .btn-apply:hover{background:#d8e030}
          .theme-gray .btn-secondary{background:#fff;color:#202428;border-color:#dfe1de}
          .theme-gray .btn-secondary:hover,.theme-gray .btn-secondary.active{background:#fafbe8;border-color:#CED629}
          .theme-gray .btn-cancel{color:#545a61;opacity:.85}
          .theme-gray .spot-action-main,.theme-gray .spot-action-small{background:#fff;color:#202428;border-color:#dfe1de}
          .theme-gray .spot-action-main:hover,.theme-gray .spot-action-small:hover,
          .theme-gray .spot-action-main.active,.theme-gray .spot-action-small.active{border-color:#CED629;background:#fafbe8}
          .theme-gray .spot-action-copy small{color:#697078}
          .theme-gray .action-icon{color:#6f7600}
          .theme-gray .replicate-icon:after{background:#fff}
        </style>
        </head>
        <body class="{{THEME_CLASS}}">
        <div class="brand">
          <button type="button" class="theme-btn" onclick="toggleTheme()" title="Fundo preto / cinza" aria-label="Alternar fundo preto ou cinza"><svg viewBox="0 0 24 24"><path d="M15.5 2.5A9.5 9.5 0 1 0 21.5 17 7.5 7.5 0 0 1 15.5 2.5Z"/></svg></button>
          <img src="{{ICON_LAMP}}" alt="">
          <div><div class="brand-name">K.LIGHT</div><div class="brand-sub">Iluminação inteligente</div></div>
        </div>

        <div class="toggle-track" id="toggle-track" onclick="handleToggleClick(event)">
          <div class="toggle-thumb"></div>
          <span class="toggle-label active" data-tab="faixa"><img src="{{ICON_LED}}" alt=""><b>LED</b></span>
          <span class="toggle-label" data-tab="spot"><img src="{{ICON_SPOT}}" alt=""><b>SPOT</b></span>
          <span class="toggle-label" data-tab="backlight"><img src="{{ICON_BACKLIGHT}}" alt=""><b>LETREIRO</b></span>
        </div>

        <!-- =================== PAINEL FAIXA =================== -->
        <div id="panel-faixa" class="panel active">

        <!-- COR -->
        <div class="section">
          <div class="stitle">Cor da luz</div>
          <div class="presets">
            <div class="pbtn active" data-p="quente" onclick="setP(this)"
              style="border-bottom:2px solid #ffc840">Quente</div>
            <div class="pbtn" data-p="neutro" onclick="setP(this)"
              style="border-bottom:2px solid #fff5c0">Neutro</div>
            <div class="pbtn" data-p="frio" onclick="setP(this)"
              style="border-bottom:2px solid #b0d8ff">Frio</div>
            <div class="pbtn" data-p="rgb" onclick="setP(this)"
              style="border-bottom:2px solid #ff50a0">RGB</div>
          </div>
          <div id="rgb-row" class="rgb-row rgb-hidden">
            <input type="color" id="rgb_color" value="#ff4400" oninput="draw();schedulePreview()">
            <span style="font-size:11px;color:#fff">Escolha qualquer cor</span>
          </div>
        </div>

        <!-- LARGURA -->
        <span class="lbl">Largura da faixa (cm)</span>
        <div class="slider-row">
          <input type="range" id="width_r" min="1" max="80" value="12"
            oninput="sync('width_r','width_n');draw();schedulePreview()">
          <input type="number" id="width_n" value="12" min="1" max="80" step="1"
            oninput="sync('width_n','width_r');draw();schedulePreview()">
        </div>

        <!-- CAMADAS -->
        <span class="lbl">Camadas <span class="val" id="lv">32</span></span>
        <div class="slider-row">
          <input type="range" id="layers" min="8" max="80" value="32"
            oninput="document.getElementById('lv').textContent=this.value;draw();schedulePreview()">
        </div>

        <!-- INTENSIDADE -->
        <span class="lbl">Intensidade <span class="val" id="av">85%</span></span>
        <div class="slider-row">
          <input type="range" id="alpha" min="10" max="100" value="85"
            oninput="document.getElementById('av').textContent=this.value+'%';draw();schedulePreview()">
        </div>

        <!-- QUEDA -->
        <span class="lbl">Queda do degradê <span class="val" id="cv">2.2</span></span>
        <div class="slider-row">
          <input type="range" id="curve" min="5" max="60" value="22"
            oninput="document.getElementById('cv').textContent=(this.value/10).toFixed(1);draw();schedulePreview()">
        </div>

        <!-- DIREÇÃO -->
        <div class="section">
          <div class="stitle">Direção da luz</div>
          <div class="dir-row">
            <div class="dbtn active" data-d="out" onclick="setDir(this)">
              <span class="icon">↔</span>
              Fora
            </div>
            <div class="dbtn" data-d="in" onclick="setDir(this)">
              <span class="icon">↩</span>
              Dentro
            </div>
          </div>
          <div class="dir-separator"></div>
          <div class="dir-row">
            <div class="vbtn" data-v="up" onclick="setVert(this)">
              <span class="icon">⬆</span>
              Cima
            </div>
            <div class="vbtn active" data-v="down" onclick="setVert(this)">
              <span class="icon">⬇</span>
              Baixo
            </div>
          </div>
        </div>

        <!-- OFFSET -->
        <span class="lbl">Offset da superfície (mm)</span>
        <div class="slider-row" style="margin-top:3px">
          <input type="number" id="offset" value="0.5" min="0.1" max="5" step="0.1"
            style="width:80px" oninput="schedulePreview()">
        </div>

        <!-- PREVIEW -->
        <span class="lbl" style="margin-top:10px">Preview</span>
        <canvas id="cv_c" width="440" height="90"></canvas>

        <button class="btn-apply" onclick="apply()">Criar LED</button>
        <button class="btn-cancel" onclick="sketchup.cancel_klight()">Cancelar</button>

        </div><!-- /panel-faixa -->

        <!-- =================== PAINEL SPOT =================== -->
        <div id="panel-spot" class="panel">

          <!-- COR DO SPOT -->
          <div class="section">
            <div class="stitle">Cor do spot</div>
            <div class="presets">
              <div class="pbtn active" data-p="quente" onclick="setPS(this)"
                style="border-bottom:2px solid #ffc840">Quente</div>
              <div class="pbtn" data-p="neutro" onclick="setPS(this)"
                style="border-bottom:2px solid #fff5c0">Neutro</div>
              <div class="pbtn" data-p="branca" onclick="setPS(this)"
                style="border-bottom:2px solid #ffffff">Branca</div>
              <div class="pbtn" data-p="rgb" onclick="setPS(this)"
                style="border-bottom:2px solid #ff50a0">RGB</div>
            </div>
            <div id="rgb-row-s" class="rgb-row rgb-hidden">
              <input type="color" id="rgb_color_s" value="#ff8800" oninput="drawS();schedulePreview()">
              <span style="font-size:11px;color:#fff">Escolha qualquer cor</span>
            </div>
          </div>

          <!-- AMPLITUDE -->
          <span class="lbl">Amplitude do facho <span class="val" id="amv">15°</span></span>
          <div class="slider-row">
            <input type="range" id="amp" min="2" max="60" value="15"
              oninput="document.getElementById('amv').textContent=this.value+'°';drawS();schedulePreview()">
          </div>

          <!-- COMPRIMENTO -->
          <span class="lbl">Comprimento do facho (cm)</span>
          <div class="slider-row">
            <input type="range" id="splen_r" min="10" max="400" value="12"
              oninput="sync('splen_r','splen_n');drawS();schedulePreview()">
            <input type="number" id="splen_n" value="12" min="10" max="400" step="1"
              oninput="sync('splen_n','splen_r');drawS();schedulePreview()">
          </div>

          <!-- INTENSIDADE -->
          <span class="lbl">Intensidade <span class="val" id="sav">80%</span></span>
          <div class="slider-row">
            <input type="range" id="salpha" min="10" max="100" value="80"
              oninput="document.getElementById('sav').textContent=this.value+'%';drawS();schedulePreview()">
          </div>

          <!-- QUEDA -->
          <span class="lbl">Queda do degradê <span class="val" id="scv">2.0</span></span>
          <div class="slider-row">
            <input type="range" id="scurve" min="5" max="60" value="20"
              oninput="document.getElementById('scv').textContent=(this.value/10).toFixed(1);drawS();schedulePreview()">
          </div>

          <!-- PREVIEW -->
          <span class="lbl" style="margin-top:10px">Preview do facho</span>
          <canvas id="cv_s" width="440" height="100"></canvas>

          <p class="hint" id="spot-hint">Após clicar em <strong>Ativar Spot</strong>, clique diretamente
            na <strong>face da luminária</strong> no modelo para gerar o cone de luz.<br>
            O facho é sempre reto, projetado para fora da face clicada.</p>

          <div class="spot-actions">
            <div class="stitle">Ações do Spot</div>
            <button class="spot-action-main" onclick="sketchup.aim_spot()"
              data-tooltip="Selecione um Spot já criado. Clique aqui e depois no ponto para onde deseja apontar o facho."
              aria-label="Direcionar Spot. Selecione um Spot já criado e depois clique no ponto do modelo para onde deseja apontar o facho.">
              <span class="action-icon target-icon"><i></i></span>
              <span class="spot-action-copy">Direcionar Spot<small>Escolha um ponto de destino</small></span>
            </button>
            <div class="spot-action-grid">
              <button class="spot-action-small" id="spot-invert-btn" onclick="toggleSpotDirection()"
                data-tooltip="Projeta o facho no lado oposto da face selecionada."
                aria-label="Inverter sentido. Projeta o facho no lado oposto da face selecionada."><span class="action-icon invert-icon"></span><span class="action-label">Inverter sentido</span></button>
              <button class="spot-action-small" onclick="replicateSpots()"
                data-tooltip="Selecione as faces das luminárias. Depois clique aqui para criar um Spot em cada face com as mesmas configurações."
                aria-label="Replicar na seleção. Cria um Spot em cada face selecionada usando as mesmas configurações atuais."><span class="action-icon replicate-icon"></span><span>Replicar na seleção</span></button>
            </div>
          </div>
          <button class="btn-apply" id="spot-apply-btn" onclick="applySpot()">◎ Ativar Spot (clique na face)</button>
          <button class="btn-cancel" onclick="sketchup.cancel_klight()">Cancelar</button>

        </div><!-- /panel-spot -->

        <!-- =================== PAINEL BACKLIGHT =================== -->
        <div id="panel-backlight" class="panel">
          <div class="section">
            <div class="stitle">Cor do Letreiro</div>
            <div class="presets">
              <div class="pbtn active" data-p="quente" onclick="setPB(this)" style="border-bottom:2px solid #ffc840">Quente</div>
              <div class="pbtn" data-p="neutro" onclick="setPB(this)" style="border-bottom:2px solid #fff5c0">Neutro</div>
              <div class="pbtn" data-p="frio" onclick="setPB(this)" style="border-bottom:2px solid #b0d8ff">Frio</div>
              <div class="pbtn" data-p="rgb" onclick="setPB(this)" style="border-bottom:2px solid #ff50a0">RGB</div>
            </div>
            <div id="rgb-row-b" class="rgb-row rgb-hidden">
              <input type="color" id="rgb_color_b" value="#ffc850" oninput="drawB();schedulePreview()">
              <span style="font-size:11px;color:#fff">Escolha qualquer cor</span>
            </div>
          </div>
          <div class="section" id="halo-style-section">
            <span class="lbl">Largura do Halo (cm)</span>
            <div class="slider-row">
              <input type="range" id="bradius_r" min="0.5" max="20" step="0.5" value="8"
                oninput="sync('bradius_r','bradius_n');drawB();schedulePreview()">
              <input type="number" id="bradius_n" value="8" min="0.5" max="25" step="0.5"
                oninput="sync('bradius_n','bradius_r');drawB();schedulePreview()">
            </div>
            <span class="lbl" style="margin-top:10px">Queda do degradê <span class="val" id="bfv">4.0</span></span>
            <div class="slider-row">
              <input type="range" id="bfalloff" min="10" max="160" value="40"
                oninput="document.getElementById('bfv').textContent=(this.value/10).toFixed(1);drawB();schedulePreview()">
            </div>
            <p class="hint" style="margin-top:6px">Largura menor já separa o brilho de letras próximas. Queda maior deixa o brilho mais concentrado na borda; menor, mais espalhado.</p>
            <p class="hint" id="halo-locked-hint" style="display:none">Este halo foi criado numa versão anterior (ou o texto original mudou) — largura e queda ficaram fixas, só cor e intensidade continuam editáveis.</p>
          </div>
          <span class="lbl">Intensidade <span class="val" id="bav">85%</span></span>
          <div class="slider-row">
            <input type="range" id="balpha" min="10" max="100" value="85"
              oninput="document.getElementById('bav').textContent=this.value+'%';drawB();schedulePreview()">
          </div>
          <span class="lbl" style="margin-top:10px">Preview do halo</span>
          <canvas id="cv_b" width="440" height="110"></canvas>
          <p class="hint">Selecione as faces que serão iluminadas.</p>
          <button class="btn-apply" onclick="applyBacklight()">Criar Letreiro</button>
          <button class="btn-cancel" onclick="sketchup.cancel_klight()">Cancelar</button>
        </div><!-- /panel-backlight -->

        <script>
        const PRESETS={quente:[255,200,80],neutro:[255,250,210],frio:[190,225,255]};
        let preset='quente', useRgb=false, direction='out', vertical='down', optimizeLines=false;
        let spotDirectionInverted=false;

        function toggleSpotDirection(){
          spotDirectionInverted=!spotDirectionInverted;
          const btn=document.getElementById('spot-invert-btn');
          btn.classList.toggle('active',spotDirectionInverted);
          const label=btn.querySelector('.action-label');
          if(label) label.textContent=spotDirectionInverted?'Sentido invertido':'Inverter sentido';
          schedulePreview();
        }

        function sync(src, dst){
          document.getElementById(dst).value = document.getElementById(src).value;
        }

        function hexToRgb(h){
          return [parseInt(h.slice(1,3),16),parseInt(h.slice(3,5),16),parseInt(h.slice(5,7),16)];
        }

        function currentRgb(){
          return useRgb ? hexToRgb(document.getElementById('rgb_color').value)
                        : (PRESETS[preset]||PRESETS.quente);
        }

        function setP(el){
          document.querySelectorAll('.pbtn').forEach(b=>b.classList.remove('active'));
          el.classList.add('active');
          preset=el.dataset.p;
          useRgb=(preset==='rgb');
          document.getElementById('rgb-row').classList.toggle('rgb-hidden', !useRgb);
          draw(); schedulePreview();
        }

        function setDir(el){
          document.querySelectorAll('.dbtn').forEach(b=>b.classList.remove('active'));
          el.classList.add('active');
          direction=el.dataset.d;
          schedulePreview();
        }

        function setVert(el){
          document.querySelectorAll('.vbtn').forEach(b=>b.classList.remove('active'));
          el.classList.add('active');
          vertical=el.dataset.v;
          schedulePreview();
        }

        function draw(){
          const cv=document.getElementById('cv_c'),ctx=cv.getContext('2d');
          const [r,g,b]=currentRgb();
          const am=document.getElementById('alpha').value/100;
          const ex=document.getElementById('curve').value/10, y=cv.height/2;
          const layerCount=parseInt(document.getElementById('layers').value)||32;
          const passes=Math.max(2,Math.min(12,Math.round(layerCount/7)));
          ctx.clearRect(0,0,cv.width,cv.height);
          ctx.fillStyle='#090a0a';ctx.fillRect(0,0,cv.width,cv.height);
          const grad=ctx.createLinearGradient(18,0,cv.width-18,0);
          grad.addColorStop(0,`rgba(${r},${g},${b},0)`);grad.addColorStop(.08,`rgba(${r},${g},${b},${am})`);
          grad.addColorStop(.92,`rgba(${r},${g},${b},${am})`);grad.addColorStop(1,`rgba(${r},${g},${b},0)`);
          ctx.lineCap='round';ctx.strokeStyle=grad;ctx.shadowColor=`rgba(${r},${g},${b},${am})`;
          for(let pass=passes;pass>=1;pass--){
            const spread=pass/passes;
            ctx.shadowBlur=(10+spread*24)/Math.max(ex*.45,.7);
            ctx.globalAlpha=(.08+.20*(1-spread))*am;
            ctx.lineWidth=2+spread*(5+passes*.7);
            ctx.beginPath();ctx.moveTo(25,y);ctx.lineTo(cv.width-25,y);ctx.stroke();
          }
          ctx.globalAlpha=1;
          ctx.shadowBlur=10;ctx.lineWidth=3;ctx.strokeStyle=`rgba(${r},${g},${b},${Math.min(1,am+.18)})`;ctx.stroke();
          ctx.shadowBlur=0;ctx.lineWidth=1;ctx.strokeStyle='rgba(255,255,235,.9)';ctx.stroke();
        }

        function apply(){
          const [r,g,b]=currentRgb();
          sketchup.apply_klight(JSON.stringify({
            width_cm:   parseFloat(document.getElementById('width_n').value)||12,
            layers:     parseInt(document.getElementById('layers').value)||32,
            alpha_max:  document.getElementById('alpha').value/100,
            curve_exp:  document.getElementById('curve').value/10,
            offset_mm:  parseFloat(document.getElementById('offset').value)||0.5,
            preset:     useRgb?'rgb':preset,
            rgb_custom: useRgb?[r,g,b]:null,
            direction:  direction,
            vertical:   vertical,
            invert:     false,
            optimize:   optimizeLines
          }));
        }

        // ---- PREVIEW AO VIVO ----
        let _previewTimer = null;
        function activeCanvas(){
          const tab = document.querySelector('.toggle-label.active').dataset.tab;
          return document.getElementById(tab==='faixa' ? 'cv_c' : (tab==='spot' ? 'cv_s' : 'cv_b'));
        }
        function schedulePreview(){
          const cv = activeCanvas();
          cv.classList.remove('live');
          cv.classList.add('pending');
          clearTimeout(_previewTimer);
          _previewTimer = setTimeout(sendPreview, 120);
        }
        function sendPreview(){
          const cv = activeCanvas();
          cv.classList.remove('pending');
          if(!sketchup.preview_klight) return;
          const tab = document.querySelector('.toggle-label.active').dataset.tab;
          if(tab === 'faixa'){
            const [r,g,b]=currentRgb();
            sketchup.preview_klight(JSON.stringify({
              tab: 'faixa',
              width_cm:  parseFloat(document.getElementById('width_n').value)||12,
              layers:    parseInt(document.getElementById('layers').value)||32,
              alpha_max: document.getElementById('alpha').value/100,
              curve_exp: document.getElementById('curve').value/10,
              offset_mm: parseFloat(document.getElementById('offset').value)||0.5,
              preset:    useRgb?'rgb':preset,
              rgb_custom:useRgb?[r,g,b]:null,
              direction: direction,
              vertical:  vertical,
              optimize:  optimizeLines
            }));
          } else if(tab === 'spot') {
            const [r,g,b]=currentRgbS();
            sketchup.preview_klight(JSON.stringify({
              tab: 'spot',
              angle_deg: parseFloat(document.getElementById('amp').value)||15,
              length_cm: parseFloat(document.getElementById('splen_n').value)||12,
              layers:    28,
              alpha_max: document.getElementById('salpha').value/100,
              curve_exp: document.getElementById('scurve').value/10,
              preset:    useRgbS?'rgb':presetS,
              rgb_custom:useRgbS?[r,g,b]:null,
              invert_direction:spotDirectionInverted
            }));
          } else {
            const [r,g,b]=currentRgbB();
            sketchup.preview_klight(JSON.stringify({
              tab: 'backlight', alpha_max: document.getElementById('balpha').value/100,
              preset: useRgbB?'rgb':presetB, rgb_custom: useRgbB?[r,g,b]:null,
              halo_radius_cm: parseFloat(document.getElementById('bradius_n').value)||8,
              halo_falloff: document.getElementById('bfalloff').value/10
            }));
          }
          // pulso breve confirmando que a alteração já foi aplicada no modelo
          cv.classList.add('live');
          setTimeout(()=>cv.classList.remove('live'), 420);
        }

        // ---- TOGGLE LED/SPOT ----
        function handleToggleClick(evt){
          const label = evt.target.closest('.toggle-label');
          switchTab(label ? label.dataset.tab : (currentTab()==='faixa' ? 'spot' : 'faixa'));
        }
        function currentTab(){
          return document.querySelector('.toggle-label.active').dataset.tab;
        }
        function switchTab(tab, skipAnim){
          const track = document.getElementById('toggle-track');
          if(skipAnim) track.classList.add('no-anim');
          track.classList.toggle('on-spot', tab==='spot');
          track.classList.toggle('on-backlight', tab==='backlight');
          document.querySelectorAll('.toggle-label').forEach(l=>l.classList.toggle('active', l.dataset.tab===tab));
          document.getElementById('panel-faixa').classList.toggle('active', tab==='faixa');
          document.getElementById('panel-spot').classList.toggle('active', tab==='spot');
          document.getElementById('panel-backlight').classList.toggle('active', tab==='backlight');
          if(tab==='spot') drawS();
          if(tab==='backlight') drawB();
          schedulePreview();
          fitDialog(tab);
          if(skipAnim){
            // devolve a transição pro próximo frame — assim o "salto" inicial
            // pro Spot (quando o diálogo já abre editando um spot) não anima,
            // mas trocas manuais de aba depois continuam deslizando normal.
            requestAnimationFrame(() => track.classList.remove('no-anim'));
          }
        }

        // ---- SPOT ----
        const PRESETS_S={quente:[255,195,90],neutro:[255,244,214],branca:[255,255,255]};
        let presetS='quente', useRgbS=false;

        function setPS(el){
          document.querySelectorAll('#panel-spot .pbtn').forEach(b=>b.classList.remove('active'));
          el.classList.add('active');
          presetS=el.dataset.p;
          useRgbS=(presetS==='rgb');
          document.getElementById('rgb-row-s').classList.toggle('rgb-hidden', !useRgbS);
          drawS(); schedulePreview();
        }

        function currentRgbS(){
          return useRgbS ? hexToRgb(document.getElementById('rgb_color_s').value)
                         : (PRESETS_S[presetS]||PRESETS_S.quente);
        }

        function drawS(){
          const cv=document.getElementById('cv_s'),ctx=cv.getContext('2d');
          const [r,g,b]=currentRgbS();
          const am=document.getElementById('salpha').value/100;
          const ex=document.getElementById('scurve').value/10;
          const angle=parseFloat(document.getElementById('amp').value)||15;
          ctx.clearRect(0,0,cv.width,cv.height);
          ctx.fillStyle='#090a0a';ctx.fillRect(0,0,cv.width,cv.height);
          const start=22,end=cv.width-22,half=Math.min(cv.height*.44,14+angle*.72),cy=cv.height/2;
          const cone=ctx.createLinearGradient(start,0,end,0);cone.addColorStop(0,`rgba(${r},${g},${b},${am})`);cone.addColorStop(.2,`rgba(${r},${g},${b},${am*.62})`);cone.addColorStop(1,`rgba(${r},${g},${b},0)`);
          ctx.save();ctx.shadowColor=`rgba(${r},${g},${b},${am})`;ctx.shadowBlur=18/Math.max(ex*.35,.65);ctx.fillStyle=cone;
          ctx.beginPath();ctx.moveTo(start,cy-3);ctx.quadraticCurveTo(cv.width*.46,cy-half*.82,end,cy-half);ctx.lineTo(end,cy+half);ctx.quadraticCurveTo(cv.width*.46,cy+half*.82,start,cy+3);ctx.closePath();ctx.fill();
          ctx.shadowBlur=10;ctx.fillStyle=`rgba(${r},${g},${b},${Math.min(1,am+.15)})`;ctx.beginPath();ctx.arc(start,cy,4,0,Math.PI*2);ctx.fill();ctx.restore();
        }

        // ---- BACKLIGHT ----
        const PRESETS_B={quente:[255,200,80],neutro:[255,250,210],frio:[190,225,255]};
        let presetB='quente', useRgbB=false;
        function setPB(el){
          document.querySelectorAll('#panel-backlight .pbtn').forEach(b=>b.classList.remove('active'));
          el.classList.add('active'); presetB=el.dataset.p; useRgbB=(presetB==='rgb');
          document.getElementById('rgb-row-b').classList.toggle('rgb-hidden', !useRgbB);
          drawB(); schedulePreview();
        }
        function currentRgbB(){
          return useRgbB ? hexToRgb(document.getElementById('rgb_color_b').value) : (PRESETS_B[presetB]||PRESETS_B.quente);
        }
        function drawB(){
          const cv=document.getElementById('cv_b'),ctx=cv.getContext('2d');
          const [r,g,b]=currentRgbB(), a=document.getElementById('balpha').value/100;
          const k = document.getElementById('bfalloff').value/10;
          const halo=parseFloat(document.getElementById('bradius_n').value)||8;
          ctx.clearRect(0,0,cv.width,cv.height);
          ctx.fillStyle='#090a0a';ctx.fillRect(0,0,cv.width,cv.height);
          const text='K.LIGHT';ctx.textAlign='center';ctx.textBaseline='middle';ctx.font='800 64px Segoe UI, Arial';
          ctx.save();ctx.shadowColor=`rgba(${r},${g},${b},${a})`;ctx.shadowBlur=(9+halo*2.8)/Math.max(k*.24,.65);ctx.lineWidth=4+Math.min(halo/3,6);ctx.strokeStyle=`rgba(${r},${g},${b},${a*.82})`;ctx.strokeText(text,cv.width/2,cv.height/2+3);ctx.restore();
          ctx.lineWidth=2;ctx.strokeStyle=`rgba(${r},${g},${b},${Math.min(1,a+.15)})`;ctx.strokeText(text,cv.width/2,cv.height/2+3);
          ctx.fillStyle='#080909';ctx.fillText(text,cv.width/2,cv.height/2+3);
        }
        function applyBacklight(){
          const [r,g,b]=currentRgbB();
          sketchup.apply_klight(JSON.stringify({tab:'backlight',alpha_max:document.getElementById('balpha').value/100,
            preset:useRgbB?'rgb':presetB,rgb_custom:useRgbB?[r,g,b]:null,
            halo_radius_cm:parseFloat(document.getElementById('bradius_n').value)||8,
            halo_falloff:document.getElementById('bfalloff').value/10}));
        }

        function applySpot(){
          const [r,g,b]=currentRgbS();
          sketchup.start_spot_pick(JSON.stringify({
            angle_deg:  parseFloat(document.getElementById('amp').value)||15,
            length_cm:  parseFloat(document.getElementById('splen_n').value)||12,
            layers:     28,
            alpha_max:  document.getElementById('salpha').value/100,
            curve_exp:  document.getElementById('scurve').value/10,
            preset:     useRgbS?'rgb':presetS,
            rgb_custom: useRgbS?[r,g,b]:null,
            invert_direction:spotDirectionInverted
          }));
        }

        // Salva alterações num spot já existente (modo edição) — ao contrário
        // de applySpot(), não pede pra clicar numa face nova: manda os
        // parâmetros direto pro mesmo caminho de commit que o LED usa.
        function applySpotSave(){
          const [r,g,b]=currentRgbS();
          sketchup.apply_klight(JSON.stringify({
            tab:        'spot',
            angle_deg:  parseFloat(document.getElementById('amp').value)||15,
            length_cm:  parseFloat(document.getElementById('splen_n').value)||12,
            layers:     28,
            alpha_max:  document.getElementById('salpha').value/100,
            curve_exp:  document.getElementById('scurve').value/10,
            preset:     useRgbS?'rgb':presetS,
            rgb_custom: useRgbS?[r,g,b]:null,
            invert_direction:spotDirectionInverted
          }));
        }

        function replicateSpots(){
          const [r,g,b]=currentRgbS();
          sketchup.replicate_spots(JSON.stringify({
            angle_deg:  parseFloat(document.getElementById('amp').value)||15,
            length_cm:  parseFloat(document.getElementById('splen_n').value)||12,
            layers:     28,
            alpha_max:  document.getElementById('salpha').value/100,
            curve_exp:  document.getElementById('scurve').value/10,
            preset:     useRgbS?'rgb':presetS,
            rgb_custom: useRgbS?[r,g,b]:null,
            invert_direction:spotDirectionInverted
          }));
        }

        // ---- PRÉ-PREENCHIMENTO (edição de grupo existente) ----
        function initDialog(d){
          if(d.batch_count){
            const subtitle=document.querySelector('.brand-sub');
            if(subtitle) subtitle.textContent=d.batch_count+' luzes selecionadas';
          }
          if(d.tab==='spot' && d.replicate){
            const btn=document.getElementById('spot-apply-btn');
            btn.textContent='◎ Criar '+d.replicate_count+' Spots';
            btn.onclick=applySpotSave;
            document.getElementById('spot-hint').textContent='As configurações serão aplicadas às faces selecionadas, criando um Spot individual em cada uma.';
          }
          if(d.tab==='faixa' && d.editing){
            document.querySelector('#panel-faixa .btn-apply').textContent = 'Salvar Alterações';
          }
          if(d.tab==='faixa' && d.editing && d.geometry_locked){
            ['width_r','width_n','layers','offset'].forEach(function(id){
              const control=document.getElementById(id); if(control) control.disabled=true;
            });
            document.querySelectorAll('#panel-faixa .dbtn,#panel-faixa .vbtn').forEach(function(button){ button.style.pointerEvents='none'; button.style.opacity='0.4'; });
            const note=document.createElement('p');
            note.className='hint';
            note.textContent='O trajeto original deste efeito não está disponível. Cor, intensidade e queda podem ser alteradas; largura e direção ficam preservadas.';
            document.querySelector('#panel-faixa .btn-apply').before(note);
          }
          // modo edição do spot: o botão de baixo salva em vez de pedir
          // pra clicar numa face nova
          if(d.tab==='spot' && d.editing){
            const btn = document.getElementById('spot-apply-btn');
            btn.textContent = '💾 Salvar Alterações';
            btn.onclick = applySpotSave;
            document.getElementById('spot-hint').style.display='none';
          }
          if(d.tab==='spot' && d.editing && d.geometry_locked){
            ['amp','splen_r','splen_n'].forEach(function(id){
              const control=document.getElementById(id); if(control) control.disabled=true;
            });
            const note=document.createElement('p');
            note.className='hint';
            note.textContent='A posição/direção original deste spot não está disponível. Cor, intensidade e queda podem ser alteradas; ângulo e comprimento ficam preservados.';
            document.getElementById('spot-apply-btn').before(note);
          }
          // modo edição do backlight: só trava estilo/largura se o SketchUp
          // não conseguiu reencontrar as faces originais do letreiro
          // (d.can_restyle vem false do Ruby nesse caso).
          if(d.tab==='backlight' && d.editing && !d.can_restyle){
            document.getElementById('halo-style-section').classList.add('locked');
            document.getElementById('halo-locked-hint').style.display='block';
          }

          switchTab(d.tab, true);

          if(d.tab==='faixa'){
            // cor
            const pbtn = document.querySelector('.pbtn[data-p="'+d.preset+'"]');
            if(pbtn) setP(pbtn);
            if(d.preset==='rgb' && d.rgb){
              document.getElementById('rgb_color').value = d.rgb;
            }
            // sliders
            if(d.width_cm){ document.getElementById('width_r').value=d.width_cm; document.getElementById('width_n').value=d.width_cm; }
            if(d.layers)  { document.getElementById('layers').value=d.layers; document.getElementById('lv').textContent=d.layers; }
            if(d.alpha_max){ const v=Math.round(d.alpha_max*100); document.getElementById('alpha').value=v; document.getElementById('av').textContent=v+'%'; }
            if(d.curve_exp){ const v=Math.round(d.curve_exp*10); document.getElementById('curve').value=v; document.getElementById('cv').textContent=d.curve_exp.toFixed(1); }
            if(d.offset_mm){ document.getElementById('offset').value=d.offset_mm; }
            // direção
            if(d.direction){ const db=document.querySelector('.dbtn[data-d="'+d.direction+'"]'); if(db) setDir(db); }
            if(d.vertical) { const vb=document.querySelector('.vbtn[data-v="'+d.vertical+'"]');  if(vb) setVert(vb); }
            // otimização automática de trajeto — o Ruby já decide sozinho
            // quando a curva tem muitos pontos (freehand/orgânica); sem
            // botão manual no painel (ver K.Light — Limpeza de Linhas na
            // toolbar pra pré-limpar arestas complexas antes de gerar).
            optimizeLines = !!d.optimize;
            draw();
          } else if(d.tab==='spot') {
            // spot
            const sbtn = document.querySelector('#panel-spot .pbtn[data-p="'+d.preset+'"]');
            if(sbtn) setPS(sbtn);
            if(d.preset==='rgb' && d.rgb){
              document.getElementById('rgb_color_s').value = d.rgb;
            }
            if(d.angle_deg){ document.getElementById('amp').value=d.angle_deg; document.getElementById('amv').textContent=d.angle_deg+'°'; }
            if(d.length_cm){ document.getElementById('splen_r').value=d.length_cm; document.getElementById('splen_n').value=d.length_cm; }
            if(d.alpha_max){ const v=Math.round(d.alpha_max*100); document.getElementById('salpha').value=v; document.getElementById('sav').textContent=v+'%'; }
            if(d.curve_exp){ const v=Math.round(d.curve_exp*10); document.getElementById('scurve').value=v; document.getElementById('scv').textContent=d.curve_exp.toFixed(1); }
            drawS();
          } else {
            const bbtn = document.querySelector('#panel-backlight .pbtn[data-p="'+(d.preset||'quente')+'"]');
            if(bbtn) setPB(bbtn);
            if(d.preset==='rgb' && d.rgb) document.getElementById('rgb_color_b').value=d.rgb;
            if(d.alpha_max){ const v=Math.round(d.alpha_max*100); document.getElementById('balpha').value=v; document.getElementById('bav').textContent=v+'%'; }
            if(d.halo_radius_cm){ document.getElementById('bradius_r').value=d.halo_radius_cm; document.getElementById('bradius_n').value=d.halo_radius_cm; }
            if(d.halo_falloff){ document.getElementById('bfalloff').value=Math.round(d.halo_falloff*10); document.getElementById('bfv').textContent=d.halo_falloff.toFixed(1); }
            drawB();
          }
        }

        // ---- AJUSTE DE ALTURA ----
        // Os painéis LED e Spot têm alturas diferentes. Em vez de medir
        // scrollHeight A CADA interação (o que causava resizes repetidos e
        // instáveis — visíveis como um "flash" branco e a janela encolhendo
        // de forma perceptível ao abrir a edição de um spot), medimos as
        // duas alturas UMA VEZ SÓ, com o documento invisível, antes do
        // diálogo aparecer pro usuário. Trocar de aba depois disso só
        // consulta esses dois números — instantâneo e sem tremor.
        let PANEL_H = { faixa: 0, spot: 0, backlight: 0 };

        function modernizeControlGrid(panelId, controlIds){
          const panel=document.getElementById(panelId), firstSection=panel&&panel.querySelector('.section');
          if(!panel||!firstSection)return;
          const grid=document.createElement('div');grid.className='control-grid';firstSection.after(grid);
          controlIds.forEach(function(id){
            const input=document.getElementById(id),row=input&&input.closest('.slider-row');
            const label=row&&row.previousElementSibling;
            if(!row||!label)return;
            const card=document.createElement('div');card.className='control-card';card.appendChild(label);card.appendChild(row);grid.appendChild(card);
          });
        }

        function modernizePanels(){
          modernizeControlGrid('panel-faixa',['width_r','layers','alpha','curve']);
          modernizeControlGrid('panel-spot',['amp','splen_r','salpha','scurve']);
        }
        function measurePanelHeights(){
          const faixaEl = document.getElementById('panel-faixa');
          const spotEl  = document.getElementById('panel-spot');
          const backlightEl = document.getElementById('panel-backlight');
          const prevVis = document.body.style.visibility;
          document.body.style.visibility = 'hidden';

          faixaEl.classList.add('active'); spotEl.classList.remove('active');
          PANEL_H.faixa = document.body.scrollHeight;

          spotEl.classList.add('active'); faixaEl.classList.remove('active');
          PANEL_H.spot = document.body.scrollHeight;

          spotEl.classList.remove('active'); backlightEl.classList.add('active');
          PANEL_H.backlight = document.body.scrollHeight;

          // devolve ao estado padrão declarado no HTML (aba LED ativa)
          faixaEl.classList.add('active'); spotEl.classList.remove('active'); backlightEl.classList.remove('active');
          document.body.style.visibility = prevVis;
        }
        function fitDialog(tab){
          if(!sketchup.resize_dialog) return;
          const h = (tab==='spot' ? PANEL_H.spot : (tab==='backlight' ? PANEL_H.backlight : PANEL_H.faixa));
          // folga maior que o conteúdo medido: o valor passado pro Ruby vira
          // a altura da JANELA inteira (set_size), que inclui a barra de
          // título/bordas do SO — sem essa folga extra o fundo do painel
          // (o botão Cancelar) ficava cortado bem na borda inferior.
          // Nunca maior que a área útil da tela (notebooks com escala 125%/150% têm pouca altura):
          // o que não couber fica acessível pela rolagem.
          const avail = (window.screen && screen.availHeight) ? screen.availHeight - 40 : 0;
          let target = h + 88;
          if(avail > 300) target = Math.min(target, avail);
          if(h) sketchup.resize_dialog(target);
        }

        function toggleTheme(){
          const gray = !document.body.classList.contains('theme-gray');
          document.body.classList.toggle('theme-gray', gray);
          document.documentElement.classList.toggle('theme-gray', gray);
          if(sketchup.set_theme) sketchup.set_theme(gray ? 'gray' : 'dark');
        }

        draw();
        drawS();
        drawB();
        modernizePanels();
        measurePanelHeights();
        // avisa o Ruby que o DOM está pronto para receber initDialog()
        if(sketchup.dialog_ready) sketchup.dialog_ready();
        </script>
        </body></html>
      HTML

      # Altura mínima e máxima aceitas do redimensionamento pedido pelo JS
      # (fitDialog). Evita que um cálculo de altura fora do esperado deixe a
      # janela gigante ou minúscula demais.
      MIN_HEIGHT = 360
      MAX_HEIGHT = 960

      # Estimativas iniciais por aba — só pra a janela já nascer perto do
      # tamanho certo. O JS corrige com precisão logo em seguida (medição
      # real, uma única vez), mas partir já perto evita o "encolher visível"
      # que acontecia antes ao abrir a edição direto na aba Spot (mais
      # curta que a LED).
      INITIAL_HEIGHT = { 'faixa' => 860, 'spot' => 850, 'backlight' => 830 }.freeze

      PREFS_SECTION = 'KahDetalha_KLight'

      def self.gray_theme?
        Sketchup.read_default(PREFS_SECTION, 'theme', 'dark') == 'gray'
      end

      def self.show(on_apply, on_cancel = nil, on_spot_pick = nil, on_preview = nil, init: nil, on_ready: nil)
        initial_h = INITIAL_HEIGHT[init && init[:tab]] || 800
        dlg = UI::HtmlDialog.new(
          dialog_title:    'K.Light',
          preferences_key: 'com.kahdetalha.klight.v9',
          style:           UI::HtmlDialog::STYLE_DIALOG,
          width: 400, height: initial_h, resizable: true, min_width: 360, min_height: 420
        )
        icons = File.join(File.dirname(__FILE__), 'icons')
        icon_url = lambda { |name| 'data:image/png;base64,' + [File.binread(File.join(icons, name))].pack('m0') }
        ui_html = HTML
          .gsub('{{ICON_LAMP}}', icon_url.call('k_ui_lamp_64.png'))
          .gsub('{{ICON_LED}}', icon_url.call('k_ui_led_64.png'))
          .gsub('{{ICON_SPOT}}', icon_url.call('k_ui_spot_64.png'))
          .gsub('{{ICON_BACKLIGHT}}', icon_url.call('k_ui_backlight_64.png'))
          .gsub('{{THEME_CLASS}}', gray_theme? ? 'theme-gray' : '')
        dlg.set_html(ui_html)

        # Trava simples pra garantir que on_cancel só roda uma vez, mesmo se
        # o usuário fechar a janela pelo X nativo depois de já ter clicado
        # em Aplicar/Cancelar (ou vice-versa).
        finished = false

        dlg.add_action_callback('apply_klight') do |_, json|
          finished = true
          on_apply.call(JSON.parse(json, symbolize_names: true))
          dlg.close
        end
        dlg.add_action_callback('cancel_klight') do |_,_|
          finished = true
          on_cancel&.call
          dlg.close
        end
        dlg.add_action_callback('start_spot_pick') do |_, json|
          finished = true
          dlg.close
          on_spot_pick&.call(JSON.parse(json, symbolize_names: true))
        end
        dlg.add_action_callback('aim_spot') do |_, _|
          finished = true
          on_cancel&.call
          dlg.close
          UI.start_timer(0, false) { KahDetalha::KLight::Spot.cmd_aim_selected_spot }
        end
        dlg.add_action_callback('replicate_spots') do |_, json|
          finished = true
          params = JSON.parse(json, symbolize_names: true)
          on_cancel&.call
          dlg.close
          UI.start_timer(0, false) { KahDetalha::KLight::Spot.replicate_from_current_selection(params) }
        end
        # Botão da lua: lembra a escolha de fundo (preto/cinza) entre sessões.
        dlg.add_action_callback('set_theme') do |_, theme|
          Sketchup.write_default(PREFS_SECTION, 'theme', theme.to_s == 'gray' ? 'gray' : 'dark')
        end
        dlg.add_action_callback('preview_klight') do |_, json|
          on_preview&.call(JSON.parse(json, symbolize_names: true))
        end
        # Ajuste dinâmico de altura pedido pelo JS (fitDialog) — LED e Spot
        # têm conteúdos de alturas diferentes; sem isso a janela ficava
        # fixa na altura do painel mais alto, sobrando espaço em branco
        # abaixo do Cancelar quando o painel menor estava ativo.
        dlg.add_action_callback('resize_dialog') do |_, h|
          h = h.to_i.clamp(MIN_HEIGHT, MAX_HEIGHT)
          dlg.set_size(400, h) rescue nil
        end
        # dialog_ready dispara depois que o DOM carregou — ponto seguro
        # para iniciar operações de modelo e injetar valores iniciais.
        dlg.add_action_callback('dialog_ready') do |_,_|
          dlg.execute_script("initDialog(#{init.to_json})") if init
          on_ready&.call
        end
        # Rede de segurança: se o usuário fechar a janela pelo X nativo do
        # SO (em vez de Cancelar), nenhuma das callbacks acima dispara — e
        # uma operação de edição aberta (start_operation) ficaria pendurada
        # no modelo, sem commit nem abort, num estado instável. Isso cobre
        # esse caminho tratando o fechamento como um cancelamento.
        dlg.set_on_closed do
          unless finished
            finished = true
            on_cancel&.call
          end
        end
        dlg.show
      end

    end # Dialog

    def self.collect_selection_edges(selection)
      edges = {}

      selection.each do |entity|
        next unless entity.valid?

        if entity.is_a?(Sketchup::Edge)
          if entity.curve
            entity.curve.edges.each { |edge| edges[edge.entityID] = edge if edge.valid? }
          else
            edges[entity.entityID] = entity
          end
        elsif entity.respond_to?(:edges)
          entity.edges.each { |edge| edges[edge.entityID] = edge if edge.is_a?(Sketchup::Edge) && edge.valid? }
        end
      end

      edges.values
    end

    # Último recurso para luzes cujo trajeto/posição salvos foram corrompidos
    # (ex.: gravados por uma versão com o bug de serialização de Length —
    # ver nota em led.rb#store_ribbon_attrs). A luz continua editável em
    # cor, intensidade e queda sem arriscar inventar uma geometria/posição
    # diferente da que já está no viewport. Os controles que mudariam a
    # forma/posição ficam travados até o usuário recriar o efeito do zero.
    def self.edit_appearance_only(model, group, init, op_name:)
      update = lambda do |params|
        intensity = params[:alpha_max].to_f.clamp(0.05, 1.0)
        previous = group.get_attribute(ATTR_DICT, 'alpha_max', 0.85).to_f.clamp(0.05, 1.0)
        rgb = params[:rgb_custom].is_a?(Array) ? params[:rgb_custom].map { |v| v.to_i.clamp(0, 255) } : PRESETS.fetch(params[:preset].to_s, PRESETS['quente'])
        group.entities.grep(Sketchup::Face).map(&:material).compact.uniq.each do |material|
          next unless material.valid?
          material.color = Sketchup::Color.new(*rgb)
          material.alpha = (material.alpha.to_f / previous * intensity).clamp(0.02, 1.0)
        end
        group.set_attribute(ATTR_DICT, 'alpha_max', intensity)
        group.set_attribute(ATTR_DICT, 'curve_exp', params[:curve_exp].to_f)
        group.set_attribute(ATTR_DICT, 'preset', params[:preset].to_s)
        group.set_attribute(ATTR_DICT, 'rgb_custom', JSON.generate(params[:rgb_custom]))
        model.active_view.invalidate
      end

      Dialog.show(
        ->(params) { update.call(params); model.commit_operation; model.selection.clear; model.selection.add(group) },
        -> { model.abort_operation }, nil,
        ->(params) { update.call(params) },
        init: init.merge(geometry_locked: true, editing: true),
        on_ready: -> { model.start_operation(op_name, true) }
      )
    end

    def self.cmd_edit
      model = Sketchup.active_model
      group = model.selection.find { |e|
        e.is_a?(Sketchup::Group) && e.valid? && e.get_attribute(ATTR_DICT, 'version')
      }
      unless group
        UI.messagebox("K.Light: selecione um grupo K.Light para editar.\n\n" \
                      "Clique no efeito de luz gerado pelo plugin e tente novamente.")
        return
      end

      kind      = group.get_attribute(ATTR_DICT, 'kind') || 'ribbon'
      preset    = group.get_attribute(ATTR_DICT, 'preset',    'quente')
      alpha_max = group.get_attribute(ATTR_DICT, 'alpha_max', 0.85).to_f
      curve_exp = group.get_attribute(ATTR_DICT, 'curve_exp', 2.2).to_f
      raw_rgb   = group.get_attribute(ATTR_DICT, 'rgb_custom', 'nil')
      rgb_arr   = Core.numeric_triplet(raw_rgb)
      rgb_hex   = rgb_arr ? '#%02x%02x%02x' % rgb_arr : '#ff8800'

      if kind == 'spot'
        raw_apex   = group.get_attribute(ATTR_DICT, 'apex',   nil)
        raw_normal = group.get_attribute(ATTR_DICT, 'normal', nil)
        # Os pontos foram salvos em coordenadas absolutas no momento da
        # criação (grupo era top-level, transform identidade). Se o
        # usuário moveu/girou o grupo depois com a ferramenta Mover, a
        # transformação do grupo mudou mas esses atributos não — sem
        # reaplicar a transformação atual aqui, a edição recriava o spot
        # na posição ORIGINAL (pré-movimentação), fazendo parecer que
        # surgia "do lado" do spot que o usuário via na tela.
        apex_values   = raw_apex   && Core.numeric_triplet(raw_apex)
        normal_values = raw_normal && Core.numeric_triplet(raw_normal)
        target_values = Core.numeric_triplet(group.get_attribute(ATTR_DICT, 'target', nil))
        tr      = group.transformation
        apex_pt = apex_values && Geom::Point3d.new(*apex_values).transform(tr)
        normal  = normal_values && Geom::Vector3d.new(*normal_values).transform(tr)
        target_pt = target_values && Geom::Point3d.new(*target_values).transform(tr)
        normal  = nil if normal && normal.length <= 1e-9
        normal&.normalize!

        # Posição/apex inválidos ou ausentes (ex.: spot criado antes do fix
        # de serialização de Length — ver led.rb#store_ribbon_attrs): não
        # dá pra reconstruir o cone com segurança, mas a luz continua
        # editável em cor/intensidade/queda sem inventar posição nova.
        unless apex_pt && normal
          edit_appearance_only(
            model, group,
            { tab: 'spot', preset: preset, rgb: rgb_hex,
              angle_deg: group.get_attribute(ATTR_DICT,'angle_deg',15).to_f,
              length_cm: group.get_attribute(ATTR_DICT,'length_cm',12).to_f,
              alpha_max: alpha_max, curve_exp: curve_exp },
            op_name: 'K.Light — Editar Spot (aparência)'
          )
          return
        end

        init = { tab: 'spot', preset: preset, rgb: rgb_hex,
                 angle_deg: group.get_attribute(ATTR_DICT,'angle_deg',15).to_f,
                 length_cm: group.get_attribute(ATTR_DICT,'length_cm',12).to_f,
                 alpha_max: alpha_max, curve_exp: curve_exp,
                 editing: true }
        default_p = { angle_deg: init[:angle_deg], length_cm: init[:length_cm],
                      layers: 28, alpha_max: alpha_max, curve_exp: curve_exp,
                      preset: preset, rgb_custom: rgb_arr }
        preview_group = nil
        prev_mats     = nil

        Dialog.show(
          ->(p) {
            if preview_group&.valid?
              final_normal = p[:invert_direction] ? normal.reverse : normal
              prev_mats = Spot.rebuild_spot(model, preview_group, apex_pt, final_normal, p, prev_mats)
              preview_group.set_attribute(ATTR_DICT,'kind','spot')
              # .to_f: mesma pegadinha de spot.rb/led.rb — Length#to_s
              # sobrescrito quebra o JSON se não convertermos antes.
              preview_group.set_attribute(ATTR_DICT,'apex',  JSON.generate([apex_pt.x.to_f, apex_pt.y.to_f, apex_pt.z.to_f]))
              preview_group.set_attribute(ATTR_DICT,'normal',JSON.generate([final_normal.x.to_f, final_normal.y.to_f, final_normal.z.to_f]))
              if target_pt && !p[:invert_direction]
                preview_group.set_attribute(ATTR_DICT,'target',JSON.generate([target_pt.x.to_f, target_pt.y.to_f, target_pt.z.to_f]))
              end
              preview_group.set_attribute(ATTR_DICT,'angle_deg', p[:angle_deg].to_f)
              preview_group.set_attribute(ATTR_DICT,'length_cm', p[:length_cm].to_f)
              preview_group.set_attribute(ATTR_DICT,'layers',    p[:layers].to_i)
              preview_group.set_attribute(ATTR_DICT,'alpha_max', p[:alpha_max].to_f)
              preview_group.set_attribute(ATTR_DICT,'curve_exp', p[:curve_exp].to_f)
              preview_group.set_attribute(ATTR_DICT,'preset',    p[:preset].to_s)
              preview_group.set_attribute(ATTR_DICT,'rgb_custom',JSON.generate(p[:rgb_custom]))
              preview_group.set_attribute(ATTR_DICT,'version',   PLUGIN_VERSION)
              group.erase! if group.valid?
              model.commit_operation
              model.selection.clear
              model.selection.add(preview_group)
            end
          },
          -> { group.hidden = false if group.valid?; model.abort_operation if preview_group },
          nil,
          ->(p) {
            next unless preview_group&.valid?
            preview_normal = p[:invert_direction] ? normal.reverse : normal
            prev_mats = Spot.rebuild_spot(model, preview_group, apex_pt, preview_normal, p, prev_mats, preview: true)
          },
          init: init,
          on_ready: -> {
            begin
              model.start_operation('K.Light — Editar Spot', true)
              group.hidden = true if group.valid?
              preview_group = model.entities.add_group
              preview_group.layer = Core.ensure_tag(model)
              result = Spot.build_spot_geo(preview_group.entities, apex_pt, normal, Core.preview_params(default_p, :spot), model)
              prev_mats = result[:materials] || []
              model.active_view.invalidate
            rescue => err
              model.abort_operation rescue nil
              UI.messagebox("K.Light: erro ao iniciar edição de spot.\n#{err.message}")
            end
          }
        )

      elsif kind == 'backlight'
        # Tenta reencontrar as faces originais do letreiro (salvas por
        # persistent_id na criação). Se conseguir, a edição volta a permitir
        # ajustar largura/queda, reconstruindo a malha; se não conseguir
        # (backlight de uma versão anterior, ou o texto original foi
        # apagado/mudou), cai pro comportamento antigo: só cor/intensidade.
        source_faces = Letreiro.find_backlight_source_faces(model, group)
        can_restyle  = !source_faces.empty?
        init = { tab: 'backlight', preset: preset, rgb: rgb_hex,
                 alpha_max: alpha_max,
                 halo_radius_cm: group.get_attribute(ATTR_DICT, 'halo_radius_cm', 8.0).to_f,
                 halo_falloff:   group.get_attribute(ATTR_DICT, 'halo_falloff',   4.0).to_f,
                 can_restyle: can_restyle,
                 editing: true }
        prev_mats = can_restyle ? group.entities.grep(Sketchup::Face).map(&:material).uniq.compact : nil
        Dialog.show(
          ->(p) {
            next unless group.valid?
            if can_restyle
              prev_mats = Letreiro.rebuild_backlight(model, group, source_faces, p, prev_mats)
              group.set_attribute(ATTR_DICT, 'halo_radius_cm', p[:halo_radius_cm].to_f)
              group.set_attribute(ATTR_DICT, 'halo_falloff', p[:halo_falloff].to_f)
            else
              Letreiro.update_backlight_appearance(group, p)
            end
            model.commit_operation
            model.selection.clear; model.selection.add(group)
          },
          -> { model.abort_operation }, nil,
          ->(p) {
            next unless group.valid?
            if can_restyle
              prev_mats = Letreiro.rebuild_backlight(model, group, source_faces, p, prev_mats, preview: true)
            else
              Letreiro.update_backlight_appearance(group, p)
            end
          },
          init: init,
          on_ready: -> { model.start_operation('K.Light — Editar Letreiro', true) }
        )

      else
        # --- RIBBON ---
        raw_pts = group.get_attribute(ATTR_DICT, 'path_pts', nil)
        # Mesmo cuidado do spot: os pontos foram salvos em coordenadas
        # absolutas com o grupo em transform identidade. Se o grupo foi
        # movido/girado depois, é preciso reaplicar a transformação atual
        # aqui, senão a edição recria a faixa na posição original.
        point_values = raw_pts && Core.numeric_point_list(raw_pts)

        # Sem trajeto salvo, ou trajeto corrompido (ex.: faixa criada antes
        # do fix de serialização de Length — ver led.rb#store_ribbon_attrs):
        # não dá pra reconstruir a malha com segurança, mas a luz continua
        # editável em cor/intensidade/queda sem inventar uma forma nova.
        unless point_values
          edit_appearance_only(
            model, group,
            { tab: 'faixa', preset: preset, rgb: rgb_hex,
              width_cm:  group.get_attribute(ATTR_DICT, 'width_cm', 12).to_f,
              layers:    group.get_attribute(ATTR_DICT, 'layers',   32).to_i,
              alpha_max: alpha_max, curve_exp: curve_exp,
              offset_mm: group.get_attribute(ATTR_DICT, 'offset_mm', 0.5).to_f,
              direction: group.get_attribute(ATTR_DICT, 'direction', 'out'),
              vertical:  group.get_attribute(ATTR_DICT, 'vertical',  'down') },
            op_name: 'K.Light — Editar LED (aparência)'
          )
          return
        end
        tr  = group.transformation
        pts = point_values.map { |point| Geom::Point3d.new(*point).transform(tr) }

        # Normal salva na criação (coordenadas de mundo). Luzes criadas
        # antes dessa versão não têm esse atributo — nesse caso caímos de
        # volta na redetecção antiga (nil vira "sem override" em ribbon_prep).
        raw_fn = group.get_attribute(ATTR_DICT, 'face_normal', nil)
        saved_normal_values = raw_fn ? Core.numeric_triplet(raw_fn) : nil
        saved_normal = saved_normal_values && Geom::Vector3d.new(*saved_normal_values).transform(tr)
        saved_normal = nil if saved_normal && saved_normal.length <= 1e-9
        saved_normal.normalize! if saved_normal

        init = { tab: 'faixa', preset: preset, rgb: rgb_hex,
                 width_cm:  group.get_attribute(ATTR_DICT,'width_cm',  12).to_f,
                 layers:    group.get_attribute(ATTR_DICT,'layers',    32).to_i,
                 alpha_max: alpha_max, curve_exp: curve_exp,
                 offset_mm: group.get_attribute(ATTR_DICT,'offset_mm', 0.5).to_f,
                 direction: group.get_attribute(ATTR_DICT,'direction', 'out'),
                 vertical:  group.get_attribute(ATTR_DICT,'vertical',  'down'), editing: true }
        default_p = { width_cm: init[:width_cm], layers: init[:layers],
                      alpha_max: alpha_max, curve_exp: curve_exp,
                      offset_mm: init[:offset_mm], preset: preset,
                      rgb_custom: rgb_arr, direction: init[:direction],
                      vertical: init[:vertical] }
        # `smart_contour` existe somente no Ruby e não volta do diálogo HTML.
        # Preserve-o em todos os callbacks para a edição usar o mesmo gerador
        # (LED Inteligente) e o mesmo lado da luz usados na criação.
        smart_contour = group.get_attribute(ATTR_DICT, 'smart_contour', false) == true
        with_kind = ->(p) { smart_contour ? p.merge(smart_contour: true) : p }
        default_p = with_kind.call(default_p)
        preview_group = nil
        prep = nil
        prev_mats = nil

        Dialog.show(
          ->(p) {
            if preview_group&.valid? && prep
              p = with_kind.call(p)
              prev_mats = Led.rebuild_ribbon(model, preview_group, prep, p, prev_mats)
              preview_group.name = "K.Light_#{p[:preset]}"
              Led.store_ribbon_attrs(preview_group, prep, p)
              group.erase! if group.valid?
              model.commit_operation
              model.selection.clear
              model.selection.add(preview_group)
            end
          },
          -> { group.hidden = false if group.valid?; model.abort_operation if preview_group },
          nil,
          ->(p) {
            next unless preview_group&.valid? && prep
            p = with_kind.call(p)
            prev_mats = Led.rebuild_ribbon(model, preview_group, prep, p, prev_mats, preview: true)
          },
          init: init,
          on_ready: -> {
            begin
              model.start_operation('K.Light — Editar LED', true)
              # Arestas temporárias pra recalcular laterais
              prep = Led.ribbon_prep_from_world_points(model, pts, saved_normal)
              raise "Trajeto inválido" unless prep
              group.hidden = true if group.valid?
              preview_group = model.entities.add_group
              preview_group.layer = Core.ensure_tag(model)
              result = Led.build_ribbon_geo(preview_group.entities, prep, Core.preview_params(default_p, :ribbon), model)
              prev_mats = result[:materials] || []
              model.active_view.invalidate
            rescue => err
              model.abort_operation rescue nil
              UI.messagebox("K.Light: erro ao iniciar edição de LED.\n#{err.message}")
            end
          }
        )
      end
    end

    # O SketchUp entra no contexto de um grupo quando ele recebe duplo clique.
    # Para grupos criados pelo K.Light, intercepta essa mudança, volta ao nível
    # anterior, seleciona a luz inteira e abre diretamente o diálogo de edição.
    class LightDoubleClickObserver < Sketchup::ModelObserver
      def onActivePathChanged(model)
        return if @opening_editor

        path = model.active_path
        group = path && path.last
        return unless group.is_a?(Sketchup::Group)
        return unless group.valid? && group.get_attribute(ATTR_DICT, 'version')

        @opening_editor = true
        UI.start_timer(0, false) do
          begin
            model.close_active while model.active_path && model.active_path.include?(group)
            model.selection.clear
            model.selection.add(group) if group.valid?
            KahDetalha::KLight.cmd_edit if group.valid?
          ensure
            @opening_editor = false
          end
        end
      end
    end

    class LightEditAppObserver < Sketchup::AppObserver
      def onNewModel(model)
        KahDetalha::KLight.attach_double_click_observer(model)
      end

      def onOpenModel(model)
        KahDetalha::KLight.attach_double_click_observer(model)
      end
    end

    def self.attach_double_click_observer(model)
      @light_edit_model_observers ||= {}
      key = model.object_id
      return if @light_edit_model_observers[key]

      observer = LightDoubleClickObserver.new
      model.add_observer(observer)
      @light_edit_model_observers[key] = observer
    end

    def self.install_double_click_edit
      attach_double_click_observer(Sketchup.active_model)
      return if @light_edit_app_observer

      @light_edit_app_observer = LightEditAppObserver.new
      Sketchup.add_observer(@light_edit_app_observer)
    end

  end
end
