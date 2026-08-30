// @gameweek/scoring — the scoring engine for all four active game modes,
// extracted from the live (post-0.8) implementations in apps/embed/index.html
// (Phase 2.3). Golden fixtures captured from production pin every behaviour;
// scoring.test.js also anti-drift-checks the pure functions against the
// inline copies still shipped in the embed.
//
// First real consumer: the Phase 3 `score-round` Edge Function. The embed
// keeps its inline copies until it modularises.
//
// Deliberate adaptation (the only one): the lineup functions take an explicit
// `squadIds` array where the inline code reads the page-global squad via
// squadFor(comp). Same behaviour when handed squadFor's output — pinned by
// the golden cases, which recorded the exact squads production resolved
// (including its LIV-squad fallback when a team has no squad rows).
//
// Known live inconsistency, preserved as-is and pinned by a test:
// buildBettingEventHistory (the leaderboard/overall path) only evaluates
// 1x2/ou25/btts, while the event-card path also scores winner/bucket markets
// via marketActual. Live comps use winner+margin, so their leaderboards
// currently ignore those markets. Phase 3's score-round must pick one
// semantics deliberately.

// ── score mode ──────────────────────────────────────────────────────────────

export function scorePoints(pred, res, scoring){
  if(!pred||!res||res.h==null||res.a==null)return[0,''];
  const s=scoring||{exactScore:5,homeGoals:2,awayGoals:2,totalGoals:1};
  // Unit comes from the competition's sport ('sets' for volleyball/tennis),
  // so the breakdown doesn't say "goals" on a volleyball match.
  const u=s.unit||'goals';
  const eH=parseInt(pred.h)==res.h,eA=parseInt(pred.a)==res.a;
  if(eH&&eA)return[s.exactScore,'Exact score correct'];
  if(eH)return[s.homeGoals,'Home team '+u+' correct'];
  if(eA)return[s.awayGoals,'Away team '+u+' correct'];
  if((parseInt(pred.h)+parseInt(pred.a))==(res.h+res.a))return[s.totalGoals,'Total '+u+' correct'];
  return[0,'No points scored'];
}

// ── betting mode ────────────────────────────────────────────────────────────

export function marketMetricValue(mkt,res){
  if(mkt.metric==='total') return res.h+res.a;
  if(mkt.metric==='margin') return Math.abs(res.h-res.a);
  return null;
}

export function marketBucketKey(mkt,res){
  const v=marketMetricValue(mkt,res);
  if(v==null||!mkt.options||!mkt.options.length) return null;
  for(const o of mkt.options){ if(o.max==null||v<=o.max) return o.key; }
  return mkt.options[mkt.options.length-1].key;
}

export function marketActual(mkt,res){
  if(mkt.type==='1x2') return res.h>res.a?'H':res.h<res.a?'A':'D';
  if(mkt.type==='ou25') return (res.h+res.a)>2.5?'O':'U';
  if(mkt.type==='btts') return (res.h>0&&res.a>0)?'Y':'N';
  if(mkt.type==='winner') return res.h>res.a?'H':'A'; // sports without draws
  return marketBucketKey(mkt,res);
}

export function buildBettingEventHistory(comp,ev,val){
  let evPts=0; const markets=[];
  (comp.markets||[]).forEach(mkt=>{
    const pick=val[mkt.type]||null;
    let isRight=false, mPts=0;
    if(ev.res){
      let actual=null;
      if(mkt.type==='1x2') actual = ev.res.h>ev.res.a?'H':ev.res.h<ev.res.a?'A':'D';
      else if(mkt.type==='ou25') actual = (ev.res.h+ev.res.a)>2.5?'O':'U';
      else if(mkt.type==='btts') actual = (ev.res.h>0&&ev.res.a>0)?'Y':'N';
      isRight = !!pick && pick===actual;
      mPts = isRight?(mkt.points||0):0;
      evPts += mPts;
    }
    markets.push({mkt,pick,isRight,pts:mPts,hasRes:!!ev.res});
  });
  return {home:ev.home,away:ev.away,res:ev.res||null,markets,evPts};
}

// ── lineup mode ─────────────────────────────────────────────────────────────

export function flattenLineupSlots(sideLineup){
  if(!sideLineup) return null;
  if(Array.isArray(sideLineup)) return sideLineup;
  return Object.values(sideLineup).filter(Boolean);
}

function inSquad(squadIds, pid){
  return !!pid && Array.isArray(squadIds) && squadIds.includes(pid);
}

export function firstGoalScorerId(scorers, squadIds){
  if(!scorers || !scorers.length) return null;
  const goals = scorers
    .filter(s=>(!s.type||s.type==='goal') && inSquad(squadIds, s.playerId))
    .slice().sort((a,b)=>(a.minute||0)-(b.minute||0));
  return goals.length ? goals[0].playerId : null;
}

export function firstSubOutPlayerIds(scorers, squadIds){
  // Returns an array — if multiple subs for the tracked team land in the
  // same minute, every one of them is a winning answer, not just whichever
  // happened to be entered/sorted first.
  if(!scorers || !scorers.length) return [];
  const subs = scorers
    .filter(s=>s.type==='sub' && inSquad(squadIds, s.outId))
    .slice().sort((a,b)=>(a.minute||0)-(b.minute||0));
  if(!subs.length) return [];
  const earliest = subs[0].minute||0;
  return subs.filter(s=>(s.minute||0)===earliest).map(s=>s.outId);
}

export function lineupBonusAnswers(ev, teamId, squadIds){
  if(!ev) return {firstGoal:null, mvp:null, firstSubOut:[]};
  const mvp = teamId
    ? (ev.homeId===teamId ? (ev.res?.mvp_home||null) : ev.awayId===teamId ? (ev.res?.mvp_away||null) : null)
    : null;
  return {
    firstGoal: firstGoalScorerId(ev.scorers, squadIds),
    firstSubOut: firstSubOutPlayerIds(ev.scorers, squadIds),
    mvp,
  };
}

// Shared scoring for a saved lineup prediction against the event it was made
// on. Each bonus question resolves independently — xiResolved and
// bonusResolvedMap let callers show "pending" instead of a false zero for
// anything not resolved yet, rather than silently mixing pending-and-wrong.
export function computeLineupRoundScore(ev, teamId, squadIds, pickedArr, bonusPicks){
  let actualXI = null;
  if(ev && ev.lineup && teamId){
    if(ev.homeId===teamId) actualXI = flattenLineupSlots(ev.lineup.home);
    else if(ev.awayId===teamId) actualXI = flattenLineupSlots(ev.lineup.away);
  }
  let xiPts=0, correctCount=0;
  const xiResolved = !!(actualXI && pickedArr && pickedArr.length===11);
  if(xiResolved){
    pickedArr.forEach(pid=>{ if(actualXI.includes(pid)){ xiPts+=10; correctCount++; } });
    if(correctCount===11) xiPts+=30;
  }
  const bonus = bonusPicks||{};
  const bonusAnswers = lineupBonusAnswers(ev, teamId, squadIds);
  const bonusResolvedMap = {
    firstGoal: !!bonusAnswers.firstGoal,
    mvp: !!bonusAnswers.mvp,
    firstSubOut: bonusAnswers.firstSubOut.length>0,
  };
  const bonusCorrect = {
    firstGoal: !!(bonusAnswers.firstGoal && bonus.firstGoal===bonusAnswers.firstGoal),
    mvp: !!(bonusAnswers.mvp && bonus.mvp===bonusAnswers.mvp),
    firstSubOut: !!(bonus.firstSubOut && bonusAnswers.firstSubOut.includes(bonus.firstSubOut)),
  };
  const bonusResolvedCount = (bonusResolvedMap.firstGoal?1:0)+(bonusResolvedMap.mvp?1:0)+(bonusResolvedMap.firstSubOut?1:0);
  const bonusCorrectCount = (bonusCorrect.firstGoal?1:0)+(bonusCorrect.mvp?1:0)+(bonusCorrect.firstSubOut?1:0);
  const bonusPts = bonusCorrectCount*30;
  return {
    actualXI, xiPts, correctCount, xiResolved,
    bonus, bonusAnswers, bonusResolvedMap, bonusCorrect, bonusResolvedCount, bonusCorrectCount, bonusPts,
    anyResolved: xiResolved || bonusResolvedCount>0,
    totalPts: xiPts+bonusPts,
  };
}

// ── ranking mode ────────────────────────────────────────────────────────────
// Ported verbatim from the inline leaderboard blocks (they exist twice in the
// embed — round + overall — with identical logic; this is the single copy).

// round.rankingTeams from the DB never has actualXG set directly — it has to
// be derived from each team's match result. Each team takes the xG from the
// FIRST resulted event it appears in (home or away), matched by name.
export function deriveRankingActuals(rankingTeams, events){
  return rankingTeams.map(t=>{
    const copy={...t};
    (events||[]).forEach(ev=>{
      if(!ev||!ev.res) return;
      if(ev.home===t.name){ const v=ev.res.home_xg; if(v!=null&&copy.actualXG==null) copy.actualXG=parseFloat(v); }
      else if(ev.away===t.name){ const v=ev.res.away_xg; if(v!=null&&copy.actualXG==null) copy.actualXG=parseFloat(v); }
    });
    return copy;
  });
}

export function rankingActualOrder(teams){
  return [...teams].sort((a,b)=>(b.actualXG||0)-(a.actualXG||0)).map(t=>t.id);
}

export function scoreRankingOrder(order, actualOrder, teamCount, rankingConfig){
  let correct=0;
  order.forEach((tid,i)=>{ if(tid===actualOrder[i]) correct++; });
  let pts=correct*(rankingConfig?.pointsPerCorrect||2);
  if(correct===teamCount) pts+=(rankingConfig?.perfectBonus||5);
  return { pts, correct };
}
