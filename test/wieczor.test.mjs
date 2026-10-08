import { test } from 'node:test';
import assert from 'node:assert/strict';
import { eveningBrief, feedbackMsg } from '../lib.js';

test('eveningBrief: o czym mówić wieczorem z Claude', () => {
  const day = { rehab: false, morning: { leki: true }, training: 'klatka', sleep_h: 8.5,
    plan: [{ text: 'Film GetMed', done: true }, { text: 'Skrypt', done: false }, { text: 'Rehab', done: false }] };
  const meals = [{ kcal: 1500, protein: 120 }, { kcal: null, protein: null }];
  const props = [{ kind: 'dzien', status: 'wzieta' }, { kind: 'dzien', status: 'odrzucona' }, { kind: 'dzien', status: 'nowa' }];
  assert.deepEqual(eveningBrief(day, meals, { kcal_target: 3300, protein_target: 150 }, props), [
    'Kalorie 1500 / 3300 – brakuje 1800 · białko 120 / 150 g · 1 posiłek bez kalorii',
    'Rehab: nie było · leki rano: tak',
    'Trening: klatka',
    'Plan: 1 / 2 zrobione – zostało: Skrypt',
    'Sen: 8,5 h',
    'Propozycje: wzięte 1, odrzucone 1, bez decyzji 1',
  ]);
  const ok = eveningBrief({ rehab: true, morning: {}, plan: [] }, [{ kcal: 3400, protein: 160 }], { kcal_target: 3300, protein_target: 150 }, []);
  assert.deepEqual(ok, ['Kalorie 3400 / 3300 – cel zrobiony · białko 160 / 150 g', 'Rehab: zrobiony · leki rano: nie', 'Trening: nie było', 'Plan: pusty']);
});

test('feedbackMsg: wiadomość do Claude o propozycji', () => {
  assert.equal(feedbackMsg({ title: 'Ustal z Davidem cenę abonamentu' }, 'chcę to ustalić z Claude'),
    'Propozycja asystenta na dziś: „Ustal z Davidem cenę abonamentu”.\nMój feedback: chcę to ustalić z Claude\nZareaguj na to teraz i zapisz wniosek w pamięci, żeby asystent brał to pod uwagę.');
});
