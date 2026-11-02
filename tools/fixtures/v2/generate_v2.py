#!/usr/bin/env python3
"""Independent media-free v2 reference vectors. Basic IEEE arithmetic only; byte-exact on both hosts."""
import json
import math
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / 'shared/fixtures/v2'


def words(count):
    return [['word', i * .5, i * .5 + .25, 'a'] for i in range(count)]


def widen(items, before, by):
    for word in items[before:]:
        word[1] += by
        word[2] += by


def paragraphs(items):
    result, start = [], 0
    while start < len(items):
        end = min(start + 150, len(items))
        natural = next((i for i in range(start + 1, end + 1) if i < len(items) and
                        (items[i][3] != items[i-1][3] or
                         items[i-1][0].endswith(('.', '?', '!', '…')) and
                         (items[i][1] - items[i-1][2] >= 1.5 or i-start >= 80))), None)
        if natural is not None:
            end = natural
        elif end < len(items):
            end = max(range(start + 120, start + 151), key=lambda i: (items[i][1] - items[i-1][2], i))
        result.append([start, end])
        start = end
    return result


def paragraph_cases():
    cases = []
    def add(name, items):
        cases.append(dict(id=name, words=items, expected=paragraphs(items)))
    for count in [0, 1, 79, 80, 149, 150, 151, 300, 10000]:
        add(f'monologue-{count}', words(count))
    items = words(9)
    for i in range(3, 6): items[i][3] = 'b'
    for i in range(6, 9): items[i][3] = None
    add('speaker-and-null-speaker', items)
    for suffix in ['.', '?', '!', '…', '.”', '']:
        items = words(8); items[2][0] = 'end' + suffix; widen(items, 3, 1.25)
        add('gap-suffix-' + (suffix or 'none'), items)
    for gap in [1.375, 1.5, 1.625]:
        items = words(8); items[2][0] = 'end.'; widen(items, 3, gap-.25)
        add(f'gap-{gap}', items)
    for sentence in [79, 80, 81]:
        items = words(320)
        for i in [sentence-1, 159, 239]: items[i][0] = 'end.'
        add(f'sentence-{sentence}-and-reset', items)
    for name, gaps in [('widest-120', [(120,.75)]), ('widest-150', [(150,.75)]),
                       ('later-tie-145', [(120,.5),(125,.5),(145,.5)]),
                       ('ignore-outside-window', [(119,4),(151,4)]),
                       ('widest-130', [(130,.75),(140,.5)])]:
        items = words(400)
        for index, gap in gaps: widen(items,index,gap)
        add(name,items)
    return cases


def pieces_result(source, queries, span, minimum):
    pieces, output = [], 0
    for a,b,c,d,kind in source:
        pieces.append(dict(source=[a,b],edited=[c,d],kind=kind))
    seams = [p['edited'][0] for i,p in enumerate(pieces) if i and p['source'][0]-pieces[i-1]['source'][1]>1e-6]
    overlaps=[]
    for axis,lo,hi in queries:
        # Independent linear reference for the half-open binary search, including empty windows.
        first=next((i for i,p in enumerate(pieces) if p[axis][1]>lo),len(pieces))
        last=next((i for i in range(first,len(pieces)) if pieces[i][axis][0]>=hi),len(pieces))
        overlaps.append([first,max(first,last)])
    gaps=[]; covered=span[0]
    for p in pieces:
        a,b=p['source']
        if b<=span[0] or a>=span[1]: continue
        if a-covered>minimum: gaps.append([covered,a])
        covered=max(covered,b)
    if span[1]-covered>minimum: gaps.append([covered,span[1]])
    return dict(pieces=pieces,editedDuration=pieces[-1]['edited'][1] if pieces else 0,
                sourceSpan=[pieces[0]['source'][0],max(pieces[0]['source'][0],pieces[-1]['source'][1])] if pieces else None,
                seams=seams,overlaps=overlaps,gaps=gaps)


def timeline_cases():
    cases=[]
    def add(name,kind,input,expected): cases.append(dict(id=name,kind=kind,input=input,expected=expected))
    def plan(name,mode,rate,raw,span,queries,minimum=.02):
        source=[];output=0
        for row in raw:
            if mode=='legacy':
                a,b=row
                if b<=a: continue
                source.append([a/rate,b/rate,output/rate,(output+b-a)/rate,'kept']);output+=b-a
            else:
                a,b,c,d,kind=row
                if d>c: source.append([a/rate,max(a,b)/rate,c/rate,d/rate,kind])
        input=dict(mode=mode,rate=rate,raw=raw,span=span,queries=queries,minimum=minimum)
        add(name,'pieces',input,pieces_result(source,queries,span,minimum))
    q=[['edited',0,1],['edited',1,2],['edited',1,1],['source',1,2],['source',-1,0],['edited',99,100]]
    plan('empty','legacy',48000,[],[0,10],q)
    plan('legacy-cuts-and-empty-piece','legacy',100,[[0,100],[200,200],[200,400],[401,500],[700,800]],[0,10],q)
    plan('scope-leading-trailing-and-small-gap','legacy',100,[[1000,1400],[1600,2000],[2001,2500],[3000,4000]],[0,60],q)
    plan('voice-patch-and-seam','voice',100,[[0,100,0,100,'kept'],[100,300,100,350,'ai'],[300,400,350,450,'kept'],[500,600,450,550,'kept'],[600,700,550,550,'ai']],[0,7],q)
    plan('voice-clamps-inverted-source','voice',4,[[8,4,0,4,'ai']],[0,4],q)
    plan('sixty-minute-1500-pieces','legacy',100,[[i*240,i*240+200] for i in range(1500)],[0,3600], [['edited',10,14.1],['source',2,4.8],['edited',2999,4000]])
    major_steps=[5,10,30,60,120,300,600,1800,3600];minor_steps=[1,5,10,30,60,300,600,1800]
    for scale in [18,17.999,9,3,.25,.01,0,-1,'NaN','Infinity']:
        valid=isinstance(scale,(int,float)) and scale>0
        major=next((s for s in major_steps if valid and s*scale>=90),3600)
        minor=next((s for s in minor_steps if valid and s<major and major%s==0 and s*scale>=6),major)
        ticks=[] if not valid else [dict(time=i*minor,major=i*minor%major==0) for i in range(math.ceil(-1/minor),math.floor(125/minor)+1)]
        add(f'ruler-{scale}','ruler',dict(scale=scale,visible=[-1,125]),dict(major=major,minor=minor,ticks=ticks))
    add('tick-work-bound','ruler',dict(scale=20,visible=[0,100000]),dict(major=5,minor=1,ticks=[]))
    for seconds,fps in [(0,30),(-1,30),('NaN',30),('Infinity',30),(443/30,30),(14.7666,30),(59.999999,30),(60,30),(3600,30),(360000,30),(1.5,24),(1.5,60),(1.5,0),(1.5,-2),(1e300,30)]:
        total=0 if not isinstance(seconds,(int,float)) or seconds<=0 or fps<=0 else min(2**62-1,math.floor(seconds*fps+1e-6))
        rate=max(1,fps);whole=total//rate;h=whole//3600;m=whole//60%60;s=whole%60;f=total%rate
        prefix='' if h else ('00:' if m else '00:00:')
        value=f'{h:02}:{m:02}:{s:02}:{f:02}' if h else (f'{m:02}:{s:02}:{f:02}' if m else f'{s:02}:{f:02}')
        add(f'timecode-{seconds}-{fps}','timecode',dict(seconds=seconds,fps=fps),dict(frame=total,dimPrefix=prefix,value=value,string=prefix+value))
    def cues(name,pages,removed):
        for axis in ['edited','source']:
            result=[]
            for i,p in enumerate(pages):
                own=p[axis];end=own[1]
                if i+1<len(pages) and pages[i+1]['edited'][0]-p['edited'][1]<=.6+1e-9:
                    end=max(end,pages[i+1][axis][0])
                if end<=own[0] or not p['text']: continue
                cuts=[[max(own[0],a),min(end,b)] for a,b in removed if b>own[0] and a<end] if axis=='source' else []
                result.append(dict(range=[own[0],end],text=p['text'],cuts=cuts))
            query=[.5,12]
            first=next((i for i,c in enumerate(result) if c['range'][1]>query[0]),len(result))
            last=next((i for i in range(first,len(result)) if result[i]['range'][0]>=query[1]),len(result))
            add(name+'-'+axis,'captions',dict(pages=pages,removed=removed,axis=axis,query=query),dict(cues=result,indices=[first,max(first,last)]))
    cues('empty',[],[])
    for gap in [.599,.6,.6000000005,.60001]:
        cues(f'hold-{gap}',[dict(edited=[0,1],source=[10,11],text='one'),dict(edited=[1+gap,3],source=[13,15],text='two')],[[10.5,10.75],[11,13],[14,20]])
    cues('overlap-and-empty',[dict(edited=[0,1],source=[10,15],text='one'),dict(edited=[1,2],source=[12,13],text='two'),dict(edited=[4,4],source=[16,16],text=''),dict(edited=[5,6],source=[17,18],text='last')],[[11,12.5],[14,16]])
    return cases


def main():
    OUT.mkdir(parents=True,exist_ok=True)
    for filename,schema,cases in [('paragraphs.json','voxclip.v2.paragraphs.v1',paragraph_cases()),('timeline-cases.json','voxclip.v2.timeline.v1',timeline_cases())]:
        data=dict(schema=schema,caseCount=len(cases),cases=cases)
        (OUT/filename).write_text(json.dumps(data,ensure_ascii=False,indent=2,allow_nan=False)+'\n',encoding='utf-8')
        print(f'{filename}: {len(cases)} cases')

if __name__=='__main__': main()
