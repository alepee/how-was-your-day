#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
model_store="${1:-$HOME/Library/Application Support/HWYD}"
app_path="${HWYD_TEST_APP:-build/How Was Your Day.app}"
mkdir -p build
fixture_dir="$(mktemp -d "$PWD/build/diarization-test.XXXXXX")"
mkdir -p "$fixture_dir/models"
cp -R "$model_store/models/diarization" "$fixture_dir/models/diarization"
if [[ -n "${HWYD_TTS_FIXTURE:-}" ]]; then
    cp "$HWYD_TTS_FIXTURE/first.wav" "$fixture_dir/first.wav"
    cp "$HWYD_TTS_FIXTURE/second.wav" "$fixture_dir/second.wav"
    cp "$HWYD_TTS_FIXTURE/tts-manifest.json" "$fixture_dir/tts-manifest.json"
else
say -v Thomas -o "$fixture_dir/first.aiff" 'Bonjour tout le monde. Nous allons parler du prototype. Je propose de commencer par la capture audio et de vérifier que les deux pistes sont bien enregistrées. Ensuite nous pourrons tester la séparation des voix et préparer la prochaine démonstration.'
say -v Amélie -o "$fixture_dir/second.aiff" 'Merci pour cette présentation. Je vais préparer les exemples pour vendredi. Il faut également vérifier la qualité des notes et garder les décisions importantes. Nous pourrons ensuite organiser une nouvelle réunion avec toute notre équipe.'
for voice in first second; do
    afconvert -f WAVE -d LEI16@16000 -c 1 "$fixture_dir/$voice.aiff" "$fixture_dir/$voice.wav"
done
fi
python3 - "$fixture_dir" <<'PY'
import wave,json,uuid,pathlib,sys,hashlib
p=pathlib.Path(sys.argv[1]); parts=[]
if (p/'tts-manifest.json').exists():
    manifest=json.loads((p/'tts-manifest.json').read_text())
    assert manifest['synthetic'] is True
    for name in ('first.wav','second.wav'):
        entry=next(u for u in manifest['utterances'] if u['file']==name)
        assert hashlib.sha256((p/name).read_bytes()).hexdigest()==entry['sha256']
for name in ['first','second','first','second']:
    with wave.open(str(p/(name+'.wav')),'rb') as w: parts.append(w.readframes(w.getnframes()))
    parts.append(b'\0'*32000)
data=b''.join(parts)
with wave.open(str(p/'conversation.wav'),'wb') as w:
    w.setparams((1,2,16000,0,'NONE','not compressed'));w.writeframes(data)
chunks=[dict(id=str(uuid.uuid4()),source=source,relativePath='conversation.wav',start=0,duration=len(data)/32000) for source in ['mic','system']]
(p/'request.json').write_text(json.dumps(dict(recordingID=str(uuid.uuid4()),locale='fr-FR',diarize=True,chunks=chunks)))
PY
"$app_path/Contents/Helpers/hwyd-pipeline" transcribe "$fixture_dir" "$fixture_dir/request.json" "$fixture_dir/result.json" > "$fixture_dir/pipeline.log" 2>&1
python3 - "$fixture_dir/result.json" <<'PY'
import json,sys,pathlib
result=json.load(open(sys.argv[1])); speakers=result['speakers']; segments=result['segments']
assert result['diarizationEngine']=='fluidaudio-0.17.7-community-1-exclusive'
for source in ['mic','system']:
    assert len([s for s in speakers if s['source']==source])==2
assert segments, "No transcript produced"
assert all(not s['confirmed'] for s in speakers)
assert len({s['id'] for s in speakers})==4
# Apple may emit punctuation-only timing runs outside a spoken turn. Keep them unattributed.
assert all(s.get('speakerID') in {p['id'] for p in speakers} for s in segments if any(c.isalnum() for c in s['text']))
assert all(s['words'] for s in segments)
assert not any(k in json.dumps(result).lower() for k in ['embedding','speakerdatabase','centroid'])
manifest_path=pathlib.Path(sys.argv[1]).parent/'tts-manifest.json'
if manifest_path.exists():
    manifest=json.loads(manifest_path.read_text())
    durations={u['file']:u['duration'] for u in manifest['utterances']}
    for source in ('mic','system'):
        offset=0; identities=[]
        for filename in ('first.wav','second.wav','first.wav','second.wav'):
            end=offset+durations[filename]; scores={}
            for segment in segments:
                speaker=segment.get('speakerID')
                if segment['source']==source and speaker:
                    scores[speaker]=scores.get(speaker,0)+max(0,min(end,segment['end'])-max(offset,segment['start']))
            assert scores and max(scores.values())>0
            identities.append(max(scores,key=scores.get)); offset=end+1
        assert identities[0]==identities[2] and identities[1]==identities[3] and identities[0]!=identities[1]
print('Offline community-1: two synthetic voices per track, timed alignment, no exported vectors: PASS')
PY

printf "Résultats : %s\n" "$fixture_dir"
