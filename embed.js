/* Gameweek seamless embed loader — https://www.gameweek.cloud
 *
 * Operators paste this instead of a fixed-height iframe:
 *
 *   <div data-gameweek data-client="yourkey"></div>
 *   <script async src="https://www.gameweek.cloud/embed.js"></script>
 *
 * Optional attributes on the container:
 *   data-comp="12,15"      only these competitions (same as the iframe's comp=)
 *   data-min-height="480"  height reserved before the first content measurement
 *
 * It still uses an iframe under the hood (the game keeps its own origin,
 * auth session, and styles), but the clunky parts are removed: the iframe is
 * borderless, transparent, and continuously sized to its content, so the
 * host page scrolls through the game as if it were part of the page.
 *
 * Protocol with the app (/embed?...&inline=1):
 *   iframe → parent  {__gameweek:true, type:'height',   height}   keep iframe content-sized
 *   iframe → parent  {__gameweek:true, type:'scroll-top'}         bring widget top into view
 *   parent → iframe  {__gameweek:true, type:'viewport', top, height}
 *                    the slice of the iframe currently visible on screen, in
 *                    iframe coordinates — the app pins its overlays to it.
 */
(function(){
  'use strict';
  if(window.GameweekEmbed) return; // script included twice — first one wins

  // Derive the app origin from wherever this script was actually loaded, so
  // the loader keeps working verbatim on staging/local copies of the site.
  var ORIGIN = 'https://www.gameweek.cloud';
  try{
    var src = document.currentScript && document.currentScript.src;
    if(src) ORIGIN = new URL(src).origin;
  }catch(e){}

  var frames = []; // {iframe, sized:false} per embedded widget

  function mount(container){
    var client = container.getAttribute('data-client');
    if(!client){
      console.warn('[Gameweek] <div data-gameweek> is missing data-client — embed skipped.');
      return;
    }
    var qs = 'client='+encodeURIComponent(client);
    var comp = container.getAttribute('data-comp');
    if(comp) qs += '&comp='+encodeURIComponent(comp);

    var iframe = document.createElement('iframe');
    iframe.src = ORIGIN+'/embed?'+qs+'&inline=1';
    iframe.title = 'Gameweek prediction game';
    // scrolling=no belts-and-braces against a double scrollbar in the moment
    // between load and the first height report.
    iframe.setAttribute('scrolling','no');
    iframe.setAttribute('allowtransparency','true');
    var minH = parseInt(container.getAttribute('data-min-height'),10);
    iframe.style.cssText = 'display:block;width:100%;border:0;background:transparent;min-height:'+((minH>0?minH:480))+'px;';
    container.appendChild(iframe);

    var entry = {iframe:iframe, sized:false};
    frames.push(entry);
    iframe.addEventListener('load', pushViewports);
  }

  // Tell each widget which slice of it is on screen right now. Overlays
  // inside the app are positioned off this, so it's refreshed on every
  // scroll/resize. scroll is listened with capture:true so widgets inside
  // inner scrollable panels still get updates.
  var rafPending = false;
  function pushViewports(){
    rafPending = false;
    var winH = window.innerHeight;
    for(var i=0;i<frames.length;i++){
      var f = frames[i].iframe;
      if(!f.contentWindow) continue;
      var rect = f.getBoundingClientRect();
      var visTop = Math.max(0, -rect.top);
      var visHeight = Math.min(rect.bottom, winH) - Math.max(rect.top, 0);
      if(visHeight <= 0) continue; // fully off-screen — keep the last band
      try{
        f.contentWindow.postMessage({__gameweek:true,type:'viewport',top:visTop,height:visHeight}, ORIGIN);
      }catch(e){}
    }
  }
  function schedulePush(){
    if(rafPending) return;
    rafPending = true;
    requestAnimationFrame(pushViewports);
  }
  window.addEventListener('scroll', schedulePush, {passive:true, capture:true});
  window.addEventListener('resize', schedulePush, {passive:true});

  window.addEventListener('message', function(e){
    if(e.origin !== ORIGIN) return;
    var d = e.data;
    if(!d || d.__gameweek !== true) return;
    for(var i=0;i<frames.length;i++){
      var entry = frames[i];
      if(entry.iframe.contentWindow !== e.source) continue;
      if(d.type === 'height'){
        var h = Number(d.height);
        if(isFinite(h) && h > 0){
          entry.iframe.style.height = Math.min(h, 1e5)+'px';
          if(!entry.sized){
            // The reserved min-height has done its anti-jump job; from here
            // the content measurement alone drives the size.
            entry.iframe.style.minHeight = '0px';
            entry.sized = true;
          }
          pushViewports();
        }
      }else if(d.type === 'scroll-top'){
        // The app switched tabs. Its content restarts from the widget top,
        // which may be scrolled past — bring it back, but only then, so we
        // never fight the user's scroll position otherwise.
        var rect = entry.iframe.getBoundingClientRect();
        if(rect.top < 0) window.scrollBy({top:rect.top-12, behavior:'smooth'});
      }
      return;
    }
  });

  function scan(){
    var containers = document.querySelectorAll('[data-gameweek]');
    for(var i=0;i<containers.length;i++){
      if(containers[i].getAttribute('data-gameweek-mounted')) continue;
      containers[i].setAttribute('data-gameweek-mounted','1');
      mount(containers[i]);
    }
  }

  // scan() is public so single-page apps can mount containers added after
  // initial load.
  window.GameweekEmbed = {scan:scan};

  if(document.readyState === 'loading'){
    document.addEventListener('DOMContentLoaded', scan);
  }else{
    scan();
  }
})();
