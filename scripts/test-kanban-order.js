#!/usr/bin/env node
// Exercise the browser's actual sorter without a browser or third-party packages.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname, '../Sources/TractandaWeb/Resources/Kanban.html'), 'utf8');
const start = source.indexOf('  const priorityCollator=');
const end = source.indexOf('  function render()', start);
assert(start >= 0 && end > start);
const context = vm.createContext({data: {usesViewSort: false}});
vm.runInContext(source.slice(start, end), context);
const tasks = [
  {id: 'blank', priority: '  ', order: -100},
  {id: 'later-high', priority: 'p1', order: 99},
  {id: 'low', priority: 'P10', order: -50},
  {id: 'earlier-high', priority: 'P1', order: -99},
  {id: 'middle', priority: 'P2', order: -10},
  {id: 'missing'},
];
const before = JSON.stringify(tasks);
const ids = () => Array.from(context.orderedBoardTasks(tasks), task => task.id);
assert.deepEqual(ids(), ['later-high', 'earlier-high', 'middle', 'low', 'blank', 'missing']);
assert.equal(JSON.stringify(tasks), before, 'Rendering must not change stored item order or values.');
context.data.usesViewSort = true;
assert.deepEqual(ids(), tasks.map(task => task.id), 'Explicit server/view ordering must remain authoritative.');
console.log('Kanban priority ordering, blank priorities, stable ties and explicit view sort passed.');
