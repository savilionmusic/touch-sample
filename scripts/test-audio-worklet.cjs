// Synthetic PCM clock test; no audio device, network or hardware.
const fs=require('fs'),vm=require('vm'),assert=require('node:assert/strict');
const html=fs.readFileSync(require('node:path').join(__dirname,'../panel-ext/touch.html'),'utf8');
const source=html.split('const WORKLETS = `')[1].split('`;')[0];
for(const rate of [44100,48000]) {
 let Player; const reports=[];
 vm.runInNewContext(source,{sampleRate:rate,AudioWorkletProcessor:class {constructor(){this.port={postMessage:m=>reports.push(m)}}},registerProcessor:(_,p)=>Player=p});
 const p=new Player(),port={}; p.port.onmessage({data:{port}});
 let inFrame=0,nextPush=0,nextRender=0,energy=0,total=0;
 while(nextRender<5000) {
  while(nextPush<=nextRender){const b=new Int16Array(512);for(let i=0;i<256;i++){const v=Math.round(8000*Math.sin(2*Math.PI*440*inFrame++/44100)); b[2*i]=b[2*i+1]=v}port.onmessage({data:b.buffer});nextPush+=256/44100*1000;}
  const l=new Float32Array(128),r=new Float32Array(128);p.process([],[[l,r]]);for(const x of l){energy+=x*x;total++;}nextRender+=128/rate*1000;
 }
 const rms=Math.sqrt(energy/total);
 assert.equal(p.under,0,`Steady 44.1 kHz input underruns at ${rate} Hz output`);
 assert.ok(rms>0.17 && rms<0.175,`Stereo sine amplitude changed at ${rate} Hz`);
 console.log(`${rate} Hz: continuous stereo sine preserved, zero underruns`);
}
