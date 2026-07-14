/* =====================================================================
   Shared corridor loop list + Open-Meteo forecast/risk helpers.
   Used by weather.html (full forecast table) and index.html (linking
   KPI locations back to weather risk on Overview / Drill-down).
   ===================================================================== */
"use strict";

/* Loop siding positions are interpolated along the corridor alignment for
   mapping/forecast purposes; loop numbering and names follow the
   WeatherWatch shutdown report. Ordered Sishen -> Saldanha Bay. */
const WX_LOOPS=[
  {loop:19, name:'Langberg',         lat:-28.0233, lon:22.6461},
  {loop:18, name:'Vrolik',           lat:-28.2620, lon:22.3079},
  {loop:17, name:'Witpan',           lat:-28.5008, lon:21.9697},
  {loop:16, name:'Rooilyf',          lat:-28.6807, lon:21.5985},
  {loop:15, name:'Oorkruis',         lat:-28.8452, lon:21.2187},
  {loop:14, name:'Rugseer',          lat:-29.0098, lon:20.8388},
  {loop:13, name:'Kenhardt',         lat:-29.1744, lon:20.4590},
  {loop:12, name:'Kolke',            lat:-29.3591, lon:20.0887},
  {loop:11, name:'Dagab',            lat:-29.5475, lon:19.7201},
  {loop:10, name:'Halfweg',          lat:-29.7464, lon:19.3573},
  {loop:9,  name:'Commissionerspan', lat:-29.9608, lon:19.0032},
  {loop:8,  name:'Sous',             lat:-30.1752, lon:18.6491},
  {loop:7,  name:'Abikwa',           lat:-30.3896, lon:18.2950},
  {loop:6,  name:'Kanakies',         lat:-30.6518, lon:18.0524},
  {loop:5,  name:'Saggiesberg',      lat:-31.0561, lon:18.1413},
  {loop:4,  name:'Knersvlakte',      lat:-31.4603, lon:18.2303},
  {loop:3,  name:'Bamboesbaai',      lat:-31.8709, lon:18.2781},
  {loop:2,  name:'Kreefbaai',        lat:-32.2833, lon:18.3142},
  {loop:1,  name:'Dwarskersbos',     lat:-32.6517, lon:18.1486},
  {loop:null, name:'Saldanha Bay', port:true, lat:-33.0117, lon:17.9442},
];

/* KPI locations store the loop as this string id: a loop number ('1'..'19')
   or 'SALDANHA' for the port. Keeps the DB column plain text. */
function wxLoopId(l){ return l.loop==null ? 'SALDANHA' : String(l.loop); }
function wxLoopById(id){ return WX_LOOPS.find(l=>wxLoopId(l)===String(id)); }
function wxLoopLabel(id){ const l=wxLoopById(id); if(!l) return id; return l.loop!=null? `L${l.loop} ${l.name}` : l.name; }

/* Inclusive range of loops between two loop ids, in corridor order —
   used to resolve a TRIM KPI's "section" (from one loop to another) to
   the set of loops whose forecast risk applies to it. */
function wxLoopsInRange(fromId, toId){
  const a = WX_LOOPS.findIndex(l=>wxLoopId(l)===String(fromId));
  const b = WX_LOOPS.findIndex(l=>wxLoopId(l)===String(toId));
  if(a<0 || b<0) return [];
  const lo=Math.min(a,b), hi=Math.max(a,b);
  return WX_LOOPS.slice(lo,hi+1);
}

/* Risk thresholds per the WeatherWatch legend:
   Amber (medium) — wind 25–40 km/h · precip 4–10 mm/day · temp <5°C or >35°C
   Red   (high)   — wind >40 km/h  · precip >10 mm/day  · temp <0°C or >40°C   */
function wxRiskLevel(rain, wind, tmin, tmax){
  if(wind>40 || rain>10 || tmin<0 || tmax>40) return 'high';
  if(wind>=25 || rain>=4 || tmin<5 || tmax>35) return 'medium';
  return 'low';
}
const RISK_RANK={low:0, medium:1, high:2};
const RISK_LABEL={low:'Low', medium:'Medium', high:'High'};

async function fetchLoopForecast(loop, days){
  const url=`https://api.open-meteo.com/v1/forecast?latitude=${loop.lat}&longitude=${loop.lon}&daily=temperature_2m_max,temperature_2m_min,precipitation_sum,wind_speed_10m_max&forecast_days=${days}&timezone=Africa%2FJohannesburg`;
  const r=await fetch(url); if(!r.ok) throw new Error('HTTP '+r.status);
  const j=await r.json(); const d=j.daily;
  const rows=d.time.map((t,i)=>{
    const rain=+d.precipitation_sum[i].toFixed(1);
    const wind=Math.round(d.wind_speed_10m_max[i]);
    const tmin=Math.round(d.temperature_2m_min[i]);
    const tmax=Math.round(d.temperature_2m_max[i]);
    return {t, rain, wind, tmin, tmax, level: wxRiskLevel(rain,wind,tmin,tmax)};
  });
  return {loop, dates:d.time, rows};
}
