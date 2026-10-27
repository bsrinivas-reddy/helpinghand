import {test,mock}from'node:test';import assert from'node:assert/strict';
mock.module(new URL('../db/db.js',import.meta.url).href,{defaultExport:{query:async()=>{throw new Error('db down');}}});
const {runMigrations}=await import('../db/migrate.js');
test('a failing migration is reported to the caller instead of being swallowed',async()=>{
    const log=mock.method(console,'error',()=>{});
    await assert.rejects(runMigrations(),/db down/);
    log.mock.restore();
});
