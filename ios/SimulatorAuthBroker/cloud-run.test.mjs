import assert from "node:assert/strict";
import test from "node:test";
import { mintCloudRunToken } from "./cloud-run.mjs";
const configuration={name:"staging",project:"nextstop-tech-testing",region:"europe-west1",service:"nextstop-broker"};

test("cloud broker uses developer IAM only at the fixed private staging token endpoint", async()=>{
  let calls=0;
  const result=await mintCloudRunToken(configuration,{
    execute:async(binary,args)=>{
      assert.equal(binary,"gcloud"); calls++;
      if(calls===1){assert.ok(args.includes("--project=nextstop-tech-testing"));return {stdout:"https://nextstop-broker-353471052580.europe-west1.run.app\n"};}
      assert.deepEqual(args,["auth","print-identity-token"]);return {stdout:"synthetic-identity\n"};
    },
    fetch:async(url,options)=>{
      assert.equal(url,"https://nextstop-broker-353471052580.europe-west1.run.app/token");
      assert.equal(options.redirect,"error"); assert.deepEqual(options.headers,{Authorization:"Bearer synthetic-identity"});
      return new Response('{"accessToken":"synthetic"}');
    }
  });
  assert.equal(result,'{"accessToken":"synthetic"}');assert.equal(calls,2);
});

test("cloud broker cannot redirect credentials or expose subprocess/private response errors",async()=>{
  for(const origin of ["https://attacker.example","https://nextstop-broker-x.run.app/private","http://nextstop-broker-x.run.app"]){
    let calls=0;
    await assert.rejects(mintCloudRunToken(configuration,{execute:async()=>{calls++;return {stdout:origin};},fetch:()=>{throw new Error("unexpected");}}),/Cloud staging broker unavailable/);
    assert.equal(calls,1);
  }
  await assert.rejects(mintCloudRunToken({...configuration,name:"production"}),/restricted/);
  await assert.rejects(mintCloudRunToken(configuration,{execute:()=>{throw new Error("private key");}}),error=>!error.message.includes("private key"));
});
