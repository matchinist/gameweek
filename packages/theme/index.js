// @gameweek/theme — the customer-theming contrast guards, extracted verbatim
// from apps/embed/index.html (Phase 2.2).
//
// Most content sits on the card surface, not the page background. If an
// customer picks a text colour that can't be read there (white text with
// white cards, say), fall back to a legible tone rather than rendering
// invisible text.
//
// The apps still carry inline copies (classic-script pages can't import
// modules yet); theme.test.js extracts those copies from the shipped HTML and
// property-checks them against this package on every run, so the copies
// cannot drift without a red build. When a page modularises, its copy is
// deleted and this becomes the only source.

export function gwLum(hex){
  var h = String(hex||'').replace('#','');
  if(h.length===3) h = h[0]+h[0]+h[1]+h[1]+h[2]+h[2];
  if(h.length<6) return null;
  var v = [0,2,4].map(function(i){
    var c = parseInt(h.substr(i,2),16)/255;
    return c<=0.03928 ? c/12.92 : Math.pow((c+0.055)/1.055,2.4);
  });
  return 0.2126*v[0] + 0.7152*v[1] + 0.0722*v[2];
}

export function gwContrast(a,b){
  var la=gwLum(a), lb=gwLum(b);
  if(la==null||lb==null) return 21;
  return (Math.max(la,lb)+0.05)/(Math.min(la,lb)+0.05);
}

// Correct/incorrect stay green and red — that mapping is universal in sports
// UIs and carries meaning the accent colour can't. But a green tuned for
// white cards turns muddy on a dark one, so pick the variant that suits the
// surface. Hue is unchanged; only lightness moves.
export function gwApplySemantics(root, surface){
  var dark = (gwLum(surface) != null) && gwLum(surface) < 0.4;
  root.setProperty('--green',       dark ? '#4ADE80' : '#16A34A');
  root.setProperty('--red',         dark ? '#F87171' : '#DC2626');
  // Pill backgrounds: a translucent tint of the chosen variant, so they
  // read on both light and dark cards.
  root.setProperty('--green-light', dark ? 'rgba(74,222,128,0.16)' : '#DCFCE7');
  root.setProperty('--red-light',   dark ? 'rgba(248,113,113,0.16)' : '#FEE2E2');
}

export function gwReadableText(text, surface){
  if(!text || !surface) return text;
  if(gwContrast(text, surface) >= 3) return text;
  // Below the readable threshold: choose whichever of dark/light actually
  // contrasts better, rather than assuming from the surface's lightness.
  // Mid-tone surfaces (a muted gold, say) are poor against both, so the
  // comparison matters.
  return gwContrast('#111111', surface) >= gwContrast('#FFFFFF', surface) ? '#111111' : '#FFFFFF';
}
