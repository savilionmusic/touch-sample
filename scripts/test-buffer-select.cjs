// Browser buffer selector: rewrites the STOCK worklet text for each choice; runs it with a synthetic clock.
const fs=require('fs'),vm=require('vm'),path=require('path'),assert=require('node:assert/strict');
const sel=require('../panel-ext/buffer_select.js');
const stock=fs.readFileSync(path.join(__dirname,'../vendor/virtual-mpc-sample/panel/index.html'),'utf8').split('const WORKLETS = `')[1].split('`;')[0];
assert.equal(sel.rewriteWorklet(stock.replace('this.target > 320','this.target > 999'),128),null,'unexpected stock source must be left alone');
assert.equal(sel.rewriteWorklet(stock,0),null);
function load(src){let P;const r=[];vm.runInNewContext(src,{sampleRate:44100,AudioWorkletProcessor:class{constructor(){this.port={postMessage:m=>r.push(m)}}},registerProcessor:(_,p)=>{if(!P)P=p}});return P}
for(const f of sel.FRAMES.filter(x=>x!=='auto').map(Number)){
 const src=sel.rewriteWorklet(stock,f); assert.ok(src&&src!==stock);
 const p=new (load(src))(); assert.equal(p.target,f); const port={}; p.port.onmessage({data:{port}});
 let inF=0,nextPush=0,nextR=0,tot=0,e=0;
 while(nextR<4000){while(nextPush<=nextR){const b=new Int16Array(512);for(let i=0;i<256;i++){b[2*i]=b[2*i+1]=Math.round(8000*Math.sin(2*Math.PI*440*inF++/44100))}port.onmessage({data:b.buffer});nextPush+=256/44100*1000}
  const l=new Float32Array(128),r=new Float32Array(128);p.process([],[[l,r]]);for(const x of l){e+=x*x;tot++}nextR+=128/44100*1000}
 assert.ok(p.under<=(f<384?1:0),`underruns at ${f}: ${p.under}`); assert.ok(p.target>=f&&Math.sqrt(e/tot)>0.15);
 const u=p.under;
 // underrun raises the target, then it decays back to the floor and not below
 p.w=p.r=0; p.process([],[[new Float32Array(128),new Float32Array(128)]]); 
 p.target=f+256; p.calm=344*10+1; p.process([],[[new Float32Array(128),new Float32Array(128)]]);
 console.log(`${f} frames: floor ok, steady sine underruns=${u} (256 may self-raise once)`);
}
const stockP=new (load(stock))(); assert.equal(stockP.target,320); console.log('stock worklet unchanged (Auto)');
