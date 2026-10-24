// app/Exporter.swift
// 把整理結果輸出成 Markdown／單檔 HTML／PDF。
import AppKit
import Foundation
import WebKit

struct DigestDoc {
    var title: String
    var meta: [(String, String)]
    var body: String                // 模型產生的 Markdown（不含 H1）
    var transcript: [String]        // 逐字稿行（可空）
    var includeTranscript: Bool
}

enum Exporter {
    static func markdown(_ d: DigestDoc) -> String {
        var s = "# \(d.title)\n\n"
        s += d.meta.map { "- **\($0.0)**：\($0.1)" }.joined(separator: "\n") + "\n\n---\n\n"
        s += d.body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        if d.includeTranscript, !d.transcript.isEmpty {
            s += "\n---\n\n## 附錄：逐字稿\n\n" + d.transcript.joined(separator: "\n\n") + "\n"
        }
        return s
    }

    /// 重點的純文字版：去掉 Markdown 符號，標題用【】，清單用「・」
    static func plainText(_ d: DigestDoc) -> String {
        var out = [d.title, String(repeating: "=", count: 24)]
        out += d.meta.map { "\($0.0)：\($0.1)" }
        out.append("")
        var inCode = false
        for raw in d.body.components(separatedBy: "\n") {
            var l = raw
            if l.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inCode.toggle(); continue }
            if inCode { out.append(l); continue }
            if let r = l.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                let t = String(l[r.upperBound...]).replacingOccurrences(of: "**", with: "")
                out += ["", "【\(t)】"]; continue
            }
            if l.range(of: #"^\s*([-*_])(\s*\1){2,}\s*$"#, options: .regularExpression) != nil { out.append(String(repeating: "-", count: 24)); continue }
            if l.range(of: #"^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$"#, options: .regularExpression) != nil { continue }   // 表格分隔線
            if l.contains("|"), l.trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                l = l.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "　｜　")
            }
            l = l.replacingOccurrences(of: #"^(\s*)[-*+]\s+\[ \]\s+"#, with: "$1☐ ", options: .regularExpression)
                .replacingOccurrences(of: #"^(\s*)[-*+]\s+\[[xX]\]\s+"#, with: "$1☑ ", options: .regularExpression)
                .replacingOccurrences(of: #"^(\s*)[-*+]\s+"#, with: "$1・", options: .regularExpression)
                .replacingOccurrences(of: #"^(\s*)>\s?"#, with: "$1｜ ", options: .regularExpression)
                .replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
                .replacingOccurrences(of: "~~", with: "")
                .replacingOccurrences(of: #"`([^`]*)`"#, with: "$1", options: .regularExpression)
                .replacingOccurrences(of: #"\[([^\]]+)\]\((https?://[^)\s]+)\)"#, with: "$1（$2）", options: .regularExpression)
            out.append(l)
        }
        var s = out.joined(separator: "\n").replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        if d.includeTranscript, !d.transcript.isEmpty {
            s += "\n\n" + String(repeating: "=", count: 24) + "\n【逐字稿】\n\n" + d.transcript.joined(separator: "\n\n")
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    /// 逐字稿 TXT：標題、來源資訊、每段一行（含時間標記）
    static func transcriptText(_ d: DigestDoc) -> String {
        var out = [d.title + "　逐字稿", String(repeating: "=", count: 24)]
        out += d.meta.map { "\($0.0)：\($0.1)" }
        return (out + ["", d.transcript.joined(separator: "\n\n")]).joined(separator: "\n") + "\n"
    }

    /// 單檔 HTML：版面與閱讀功能（自動／淺色／米黃／深色、字級行距、閱讀進度、上一節／下一節）沿用 RP/build_reader.py，
    /// 因為一檔一份，不放封面與總目錄。forPrint＝產生 PDF 用（固定淺色、隱藏工具列、展開逐字稿）
    /// toc＝true：多章節的書（合併多份 Markdown）會多出目錄抽屜（☰、搜尋）、列印用目錄頁，並讓每個 # 章節從新頁開始
    static func html(_ d: DigestDoc, forPrint: Bool = false, toc: Bool = false) -> String {
        let rendered = Markdown.render(d.body)
        let bodyHTML = rendered.html
        var tocLinks = "", printToc = ""
        if toc {
            for h in rendered.headings where h.level <= 2 {
                let t = Markdown.escape(h.text)
                tocLinks += "<a class=\"\(h.level == 1 ? "t1" : "t2")\" href=\"#\(h.id)\" data-t=\"\(h.id)\">\(t)</a>"
                printToc += "<div class=\"\(h.level == 1 ? "p1" : "p2")\"><a href=\"#\(h.id)\">\(t)</a></div>"
            }
        }
        let meta = d.meta.map { "<span><b>\(Markdown.escape($0.0))</b>\(Markdown.escape($0.1))</span>" }.joined()
        var transcript = ""
        if d.includeTranscript, !d.transcript.isEmpty {
            transcript = "<details class=\"transcript\"\(forPrint ? " open" : "")><summary id=\"transcript\">逐字稿</summary>"
                + d.transcript.map { "<p>\(Markdown.inline($0))</p>" }.joined() + "</details>"
        }
        let key = "pd:" + String(d.title.unicodeScalars.reduce(5381) { ($0 &* 33 &+ Int($1.value)) & 0xFFFFFF }, radix: 36)
        return """
        <!doctype html>
        <html lang="zh-Hant" data-theme="\(forPrint ? "light" : "auto")"\(forPrint ? " data-print" : "")\(toc ? " class=\"book\"" : "")><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
        <title>\(Markdown.escape(d.title))</title>
        <meta name="theme-color" content="#fbfbfd">
        <style>\(css)</style></head><body>
        <div id="bar"></div>
        <header id="top">\(toc ? "<button class=\"ib\" id=\"btnToc\" aria-label=\"目錄\">☰</button>" : "<span class=\"ib\" style=\"visibility:hidden\"></span>")<div class="ttl"><b>\(Markdown.escape(d.title))</b><span id="cur">開頭</span></div>
        <button class="ib" id="btnSet" aria-label="閱讀設定">Aa</button></header>
        <div id="scrim"></div>
        \(toc ? "<aside id=\"drawer\"><header><h2>目錄</h2><button class=\"ib\" id=\"closeToc\" aria-label=\"關閉\">✕</button></header><input id=\"q\" type=\"search\" placeholder=\"搜尋目錄…\" aria-label=\"搜尋目錄\"><nav id=\"toc\">\(tocLinks)</nav></aside>" : "")
        <div id="panel" role="dialog" aria-label="閱讀設定">
        <div class="row"><span>字級</span><div class="seg"><button data-fs="-0.1">A−</button><button data-fs="0.1">A＋</button></div></div>
        <div class="row"><span>行距</span><div class="seg"><button data-lh="1.7">緊湊</button><button data-lh="1.95">標準</button><button data-lh="2.2">寬鬆</button></div></div>
        <div class="row"><span>主題</span><div class="seg"><button data-th="auto">自動</button><button data-th="light">淺色</button><button data-th="sepia">米黃</button><button data-th="dark">深色</button></div></div></div>
        <main><section class="head"><h1>\(Markdown.escape(d.title))</h1><div class="meta">\(meta)</div></section>
        \(toc ? "<section class=\"ptoc\"><h2>目錄</h2>\(printToc)</section>" : "")
        <article>\(bodyHTML)</article>
        \(transcript)
        <p class="end">— 由 PodDigest 整理 —</p></main>
        <div id="nav"><button id="prev">‹ 上一節</button><button id="next">下一節 ›</button></div>
        <div id="toast" role="status"></div>
        <script>\(js.replacingOccurrences(of: "__KEY__", with: key))</script></body></html>
        """
    }

    // 樣式沿用 RP/build_reader.py 的 WEB_CSS（主色 #0f6b5c、深色用提亮的 #55b1a2）
    static let css = """
    :root{--bg:#fbfbfd;--fg:#1d1d1f;--mut:#6e6e73;--line:#e3e3e8;--card:#fff;--acc:#0f6b5c;--accbg:#f3f3f7;--quote:#f2f4f8;--fs:1;--lh:1.95}
    :root[data-theme=dark]{--bg:#111113;--fg:#e8e8ec;--mut:#9a9aa3;--line:#2a2a30;--card:#1a1a1d;--acc:#55b1a2;--accbg:#202025;--quote:#1b1d22}
    :root[data-theme=sepia]{--bg:#f5ecd9;--fg:#3b3226;--mut:#85755d;--line:#e2d4b6;--card:#faf3e3;--acc:#0f6b5c;--accbg:#efe4cb;--quote:#eee2c6}
    @media (prefers-color-scheme:dark){:root[data-theme=auto]{--bg:#111113;--fg:#e8e8ec;--mut:#9a9aa3;--line:#2a2a30;--card:#1a1a1d;--acc:#55b1a2;--accbg:#202025;--quote:#1b1d22}}
    *{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
    html{-webkit-text-size-adjust:100%;text-size-adjust:100%;scroll-behavior:auto}
    body{margin:0;background:var(--bg);color:var(--fg);font-family:'-apple-system','BlinkMacSystemFont','SF Pro','SF Pro Display','PingFang TC','Inter','Roboto','AppleGothic','Microsoft JhengHei UI',sans-serif;font-size:calc(17px*var(--fs));line-height:var(--lh);padding-bottom:env(safe-area-inset-bottom);overflow-wrap:anywhere;text-rendering:optimizeLegibility}
    button{font:inherit;color:inherit;background:none;border:0;cursor:pointer}
    #bar{position:fixed;top:0;left:0;height:3px;width:0;background:var(--acc);z-index:60;transition:width .1s linear}
    #top{position:fixed;top:0;left:0;right:0;z-index:50;display:flex;align-items:center;gap:6px;padding:calc(env(safe-area-inset-top) + 6px) max(10px,env(safe-area-inset-right)) 6px max(10px,env(safe-area-inset-left));background:color-mix(in srgb,var(--bg) 86%,transparent);-webkit-backdrop-filter:saturate(180%) blur(18px);backdrop-filter:saturate(180%) blur(18px);border-bottom:1px solid var(--line)}
    #top .ttl{flex:1;min-width:0;line-height:1.25;text-align:center}
    #top .ttl b{display:block;font-size:13px;color:var(--mut);font-weight:500;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
    #top .ttl span{display:block;font-size:15px;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
    .ib{width:42px;height:42px;border-radius:12px;font-size:18px;font-weight:600;display:grid;place-items:center;flex:none}
    .ib:hover,.ib:active{background:var(--accbg)}
    #nav{position:fixed;left:0;right:0;bottom:0;z-index:40;display:flex;justify-content:center;gap:10px;padding:8px 12px calc(env(safe-area-inset-bottom) + 8px);pointer-events:none}
    #nav button{pointer-events:auto;padding:9px 18px;border-radius:999px;background:var(--card);border:1px solid var(--line);box-shadow:0 2px 10px rgba(0,0,0,.12);font-size:14px;font-weight:600}
    #nav button:disabled{opacity:.35}
    #scrim{position:fixed;inset:0;background:rgba(0,0,0,.4);z-index:70;opacity:0;pointer-events:none;transition:opacity .2s}
    body.set #scrim{opacity:1;pointer-events:auto}
    #panel{position:fixed;left:0;right:0;bottom:0;z-index:80;background:var(--card);border-radius:20px 20px 0 0;padding:16px 18px calc(env(safe-area-inset-bottom) + 20px);transform:translateY(105%);transition:transform .25s;box-shadow:0 -6px 30px rgba(0,0,0,.25);max-width:560px;margin:0 auto}
    body.set #panel{transform:none}
    #panel .row{display:flex;align-items:center;gap:10px;margin:12px 0}
    #panel .row>span{width:64px;color:var(--mut);font-size:14px;flex:none}
    #panel .seg{display:flex;flex:1;border:1px solid var(--line);border-radius:10px;overflow:hidden}
    #panel .seg button{flex:1;padding:9px 0;font-size:14px;border-right:1px solid var(--line)}
    #panel .seg button:last-child{border:0}
    #panel .seg button.on{background:var(--acc);color:#fff}
    main{max-width:42rem;margin:0 auto;padding:calc(env(safe-area-inset-top) + 74px) max(18px,env(safe-area-inset-right)) 120px max(18px,env(safe-area-inset-left))}
    .head{padding:14px 0 6px}
    .head h1{font-size:1.9em;line-height:1.3;margin:0 0 .5em;padding-bottom:.3em;border-bottom:2px solid var(--acc)}
    .meta{display:flex;flex-wrap:wrap;gap:2px 18px;color:var(--mut);font-size:.82em;line-height:1.7}
    .meta b{color:var(--acc);font-weight:600;margin-right:5px}
    h1,h2,h3,h4,h5,h6{line-height:1.4;scroll-margin-top:70px;font-weight:700;letter-spacing:.01em}
    article h2{font-size:1.4em;margin:2.2em 0 .7em;color:var(--acc)}
    article h3{font-size:1.15em;margin:1.8em 0 .5em;padding-left:.6em;border-left:4px solid var(--acc)}
    article h4,article h5{font-size:1.02em;margin:1.4em 0 .4em}
    p{margin:.85em 0}
    ul,ol{padding-left:1.35em;margin:.5em 0} li{margin:.3em 0} li>ul,li>ol{margin:.2em 0}
    li.task{list-style:none;margin-left:-1.2em} li.done{color:var(--mut)}
    blockquote{margin:1.1em 0;padding:.4em 1em;background:var(--quote);border-left:4px solid var(--acc);border-radius:0 10px 10px 0}
    blockquote p{margin:.5em 0}
    code{font-family:'SF Mono',ui-monospace,Menlo,'PingFang TC',monospace;background:var(--accbg);padding:1px 5px;border-radius:5px;font-size:.88em}
    pre{background:var(--accbg);padding:12px;border-radius:10px;overflow:auto;white-space:pre-wrap;word-break:break-all} pre code{background:none;padding:0}
    .tbl{overflow-x:auto;margin:1em 0} table{border-collapse:collapse;max-width:100%;font-size:.92em}
    th,td{border:1px solid var(--line);padding:6px 10px;vertical-align:top} th{background:var(--accbg)}
    hr{border:0;border-top:1px solid var(--line);margin:2em 0} a{color:var(--acc)}
    .ts{color:var(--mut);font-size:.82em;white-space:nowrap}
    .transcript{margin-top:3em;border-top:1px solid var(--line);padding-top:1em}
    .transcript summary{cursor:pointer;font-weight:700;font-size:1.15em}
    .transcript p{font-size:.88em;color:var(--mut);line-height:1.85}
    .end{text-align:center;color:var(--mut);margin:4em 0 2em;font-size:.85em}
    #toast{position:fixed;left:50%;bottom:calc(env(safe-area-inset-bottom) + 76px);transform:translate(-50%,30px);opacity:0;z-index:90;background:#1d1d1fee;color:#fff;padding:11px 16px;border-radius:14px;font-size:14px;display:flex;gap:12px;align-items:center;max-width:92vw;width:max-content;transition:.3s;pointer-events:none}
    #toast.show{opacity:1;transform:translate(-50%,0);pointer-events:auto}
    #toast button{color:#9fd0ff;font-weight:600;white-space:nowrap}
    article h1{font-size:1.65em;margin:2.6em 0 .8em;padding-bottom:.35em;border-bottom:2px solid var(--acc)}
    body.toc #scrim{opacity:1;pointer-events:auto}
    #drawer{position:fixed;top:0;bottom:0;left:0;width:min(88vw,400px);z-index:80;background:var(--card);transform:translateX(-102%);transition:transform .25s;display:flex;flex-direction:column;padding-top:env(safe-area-inset-top);box-shadow:4px 0 24px rgba(0,0,0,.2)}
    body.toc #drawer{transform:none}
    #drawer header{padding:12px 14px 8px;display:flex;gap:8px;align-items:center}
    #drawer h2{margin:0;font-size:18px;flex:1}
    #q{width:calc(100% - 28px);margin:0 14px 8px;padding:10px 12px;border-radius:10px;border:1px solid var(--line);background:var(--bg);color:var(--fg);font:inherit;font-size:16px}
    #toc{overflow:auto;flex:1;padding:0 8px calc(env(safe-area-inset-bottom) + 20px);overscroll-behavior:contain}
    #toc a{display:block;text-decoration:none;color:var(--fg);padding:9px 10px;border-radius:10px;line-height:1.45;font-size:15px}
    #toc a.t1{font-weight:700;margin-top:10px;color:var(--acc)} #toc a.t2{padding-left:22px;font-size:14.5px}
    #toc a.on{background:var(--accbg);font-weight:600;box-shadow:inset 3px 0 0 var(--acc)} #toc a.x{display:none}
    .ptoc{display:none}
    @media (min-width:900px){body{font-size:calc(18px*var(--fs))}}
    @media print{#top,#nav,#bar,#panel,#scrim,#toast,#drawer{display:none!important}main{padding-top:0;max-width:none}
      .book .ptoc{display:block;break-after:page} .ptoc h2{font-size:1.5em;margin:0 0 .6em;color:var(--acc)}
      .ptoc .p1{font-weight:700;margin-top:.8em} .ptoc .p2{margin-left:1.2em;font-size:.92em;line-height:1.7} .ptoc a{color:inherit}
      .book article h1{break-before:page;margin-top:0} .book article h1:first-child{break-before:auto}
      body{font-size:10.5pt;line-height:1.8} article h2,article h3,article h4{break-after:avoid} li,blockquote,tr,pre{break-inside:avoid}
      a{color:inherit;text-decoration:none}}
    """

    // 互動邏輯沿用 build_reader.py：設定記在 localStorage、進度條、目前章節、上一節／下一節、還原閱讀位置
    static let js = #"""
    (function(){'use strict';
    var KEY='__KEY__',SK='pd:settings';
    var $=function(s){return document.querySelector(s)},de=document.documentElement,body=document.body;
    function lsGet(k){try{return localStorage.getItem(k)}catch(e){return null}}
    function lsSet(k,v){try{localStorage.setItem(k,v)}catch(e){}}
    var S={fs:1,lh:1.95,theme:'auto'};
    try{var s0=JSON.parse(lsGet(SK)||'{}');for(var k in s0)S[k]=s0[k]}catch(e){}
    var printMode=de.hasAttribute('data-print');      // 產生 PDF：固定淺色，不讀寫閱讀設定與進度
    if(printMode)S.theme='light';
    function apply(){
      de.style.setProperty('--fs',S.fs);de.style.setProperty('--lh',S.lh);de.setAttribute('data-theme',S.theme);
      document.querySelectorAll('#panel [data-th]').forEach(function(b){b.classList.toggle('on',b.dataset.th===S.theme)});
      document.querySelectorAll('#panel [data-lh]').forEach(function(b){b.classList.toggle('on',+b.dataset.lh===S.lh)});
      if(!printMode)lsSet(SK,JSON.stringify(S));
    }
    apply();
    var heads=[].slice.call(document.querySelectorAll('article h1,article h2,article h3,article h4,#transcript')),
        secs=[].slice.call(document.querySelectorAll('article h1,article h2,#transcript')),
        tocLinks={};
    document.querySelectorAll('#toc a').forEach(function(a){tocLinks[a.dataset.t]=a});
    function lastBefore(list,y){var lo=0,hi=list.length-1,r=-1;while(lo<=hi){var m=(lo+hi)>>1;if(list[m].getBoundingClientRect().top<=y){r=m;lo=m+1}else hi=m-1}return r}
    var cur=-2,saveT=0;
    function save(){
      var max=de.scrollHeight-innerHeight;
      if(scrollY<300){lsSet(KEY,'');return}
      var i=lastBefore(heads,20);if(i<0)return;
      var h=heads[i];if(!h.id)return;
      lsSet(KEY,h.id+'~'+Math.max(0,Math.round(-h.getBoundingClientRect().top+20))+'~'+Math.round(scrollY/Math.max(1,max)*1000));
    }
    var ticking=false;
    function onScroll(){
      if(ticking)return;ticking=true;
      requestAnimationFrame(function(){
        ticking=false;
        var y=scrollY,max=de.scrollHeight-innerHeight;
        $('#bar').style.width=(max>0?y/max*100:0)+'%';
        var i=lastBefore(secs,90);
        if(i!==cur){cur=i;$('#cur').textContent=i>=0?secs[i].textContent:'開頭';
          var o=$('#toc a.on');if(o)o.classList.remove('on');if(i>=0&&tocLinks[secs[i].id])tocLinks[secs[i].id].classList.add('on');$('#prev').disabled=i<0;$('#next').disabled=i>=secs.length-1}
        clearTimeout(saveT);saveT=setTimeout(save,700);
      });
    }
    addEventListener('scroll',onScroll,{passive:true});addEventListener('resize',onScroll);addEventListener('pagehide',save);
    function go(el){scrollTo(0,el.getBoundingClientRect().top+scrollY-62)}
    $('#prev').onclick=function(){var i=lastBefore(secs,90);if(i>=0&&secs[i].getBoundingClientRect().top<-120)go(secs[i]);else if(i>0)go(secs[i-1]);else scrollTo(0,0)};
    $('#next').onclick=function(){var i=lastBefore(secs,90)+1;if(i<secs.length)go(secs[i])};
    $('#btnSet').onclick=function(){body.classList.remove('toc');body.classList.add('set')};
    $('#scrim').onclick=function(){body.classList.remove('set','toc')};
    if($('#toc')){
      $('#btnToc').onclick=function(){body.classList.remove('set');body.classList.add('toc');var a=$('#toc a.on');if(a)a.scrollIntoView({block:'center'})};
      $('#closeToc').onclick=function(){body.classList.remove('toc')};
      $('#toc').addEventListener('click',function(e){var a=e.target.closest('a');if(!a)return;e.preventDefault();body.classList.remove('toc');var el=document.getElementById(a.dataset.t);if(el)go(el)});
      $('#q').addEventListener('input',function(){var q=this.value.trim().toLowerCase();document.querySelectorAll('#toc a').forEach(function(a){a.classList.toggle('x',!!q&&a.textContent.toLowerCase().indexOf(q)<0)})});
    }
    $('#panel').addEventListener('click',function(e){
      var b=e.target.closest('button');if(!b)return;
      if(b.dataset.fs)S.fs=Math.min(1.8,Math.max(.8,+(S.fs+ +b.dataset.fs).toFixed(2)));
      if(b.dataset.th)S.theme=b.dataset.th;
      if(b.dataset.lh)S.lh=+b.dataset.lh;
      apply();
    });
    var toastT;
    function toast(msg,btn,fn){var t=$('#toast');t.innerHTML='';var s=document.createElement('span');s.textContent=msg;t.appendChild(s);
      if(btn){var b=document.createElement('button');b.textContent=btn;b.onclick=function(){fn();t.classList.remove('show')};t.appendChild(b)}
      t.classList.add('show');clearTimeout(toastT);toastT=setTimeout(function(){t.classList.remove('show')},6000)}
    var v=lsGet(KEY);
    if(v&&!location.hash&&!printMode){var a=v.split('~'),el=document.getElementById(a[0]);
      if(el){var restore=function(){scrollTo(0,el.getBoundingClientRect().top+scrollY-20+(+a[1]||0));cur=-2;onScroll();toast('已回到上次閱讀位置','從頭開始',function(){scrollTo(0,0)})};
        if(document.readyState==='complete')setTimeout(restore,30);else addEventListener('load',function(){setTimeout(restore,30)})}}
    if('scrollRestoration' in history)history.scrollRestoration='manual';
    onScroll();
    })();
    """#

    static func safeName(_ s: String) -> String {
        var t = s.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")).joined(separator: " ")
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespaces))
        if t.count > 80 { t = String(t.prefix(80)) }
        return t.isEmpty ? "未命名" : t
    }

    /// 寫出所選格式，檔名重複時加編號。回傳寫出的檔案
    @MainActor
    static func write(_ d: DigestDoc, formats: Set<OutputFormat>, dir: URL, toc: Bool = false) async throws -> [URL] {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = safeName(d.title)
        var stem = base, n = 2
        while OutputFormat.allCases.contains(where: { fm.fileExists(atPath: dir.appendingPathComponent("\(stem)\($0.suffix).\($0.ext)").path) }) {
            stem = "\(base) \(n)"; n += 1
        }
        var out: [URL] = []
        for f in OutputFormat.allCases where formats.contains(f) {
            let url = dir.appendingPathComponent("\(stem)\(f.suffix).\(f.ext)")
            switch f {
            case .md: try markdown(d).write(to: url, atomically: true, encoding: .utf8)
            case .html: try html(d, toc: toc).write(to: url, atomically: true, encoding: .utf8)
            case .pdf: try await PDFRenderer.render(html: html(d, forPrint: true, toc: toc), to: url)
            case .txt: try plainText(d).write(to: url, atomically: true, encoding: .utf8)
            case .transcript: try transcriptText(d).write(to: url, atomically: true, encoding: .utf8)
            }
            out.append(url)
        }
        return out
    }
}

/// 用 WKWebView 的列印功能產生分頁 A4 PDF
@MainActor
final class PDFRenderer: NSObject, WKNavigationDelegate {
    private var cont: CheckedContinuation<Void, Error>?
    private let web: WKWebView
    private let window: NSWindow

    private override init() {
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 595, height: 842))
        window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 595, height: 842),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = web
        super.init()
        web.navigationDelegate = self
    }

    static func render(html: String, to url: URL) async throws {
        let r = PDFRenderer()
        try await r.load(html)
        try await r.print(to: url)
    }

    private func load(_ html: String) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            cont = c
            web.loadHTMLString(html, baseURL: nil)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in self.cont?.resume(); self.cont = nil }
    }
    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.cont?.resume(throwing: error); self.cont = nil }
    }

    private final class Done: NSObject {
        var cb: ((Bool) -> Void)?
        @objc func finished(_ op: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) { cb?(success) }
    }

    private func print(to url: URL) async throws {
        try? await Task.sleep(nanoseconds: 300_000_000)          // 等排版完成
        let info = NSPrintInfo()
        info.paperSize = NSSize(width: 595, height: 842)
        info.topMargin = 40; info.bottomMargin = 44; info.leftMargin = 40; info.rightMargin = 40
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        let op = web.printOperation(with: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        op.view?.frame = NSRect(x: 0, y: 0, width: 595, height: 842)
        let done = Done()
        let ok: Bool = await withCheckedContinuation { c in
            done.cb = { c.resume(returning: $0) }
            op.runModal(for: window, delegate: done, didRun: #selector(Done.finished(_:success:contextInfo:)), contextInfo: nil)
        }
        withExtendedLifetime(done) {}
        if !ok || !FileManager.default.fileExists(atPath: url.path) { throw AppError("PDF 產生失敗") }
    }
}
