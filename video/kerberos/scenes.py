"""Kerberos teaching model, derived trace, and modal narration scenes."""
import json
from pathlib import Path
from manim import *

ROOT = Path(__file__).parent
BG, BLUE, GREEN, GOLD, RED = '#111111', '#60a5fa', '#4ade80', '#fbbf24', '#f87171'


def trace():
    events = []
    def emit(task, src, dst, message, prior):
        eid = f'e{len(events):03}'
        events.append(dict(id=eid, task=task, src=src, dst=dst, message=message, prior=prior))
        return eid
    login = emit('login','Alice','AS','AS-REQ',[])
    login = emit('login','AS','Alice','AS-REP',[login])
    for run in range(3):
        parent = emit(f'workspace/{run}','Alice','Workspace','start',[login])
        ends = []
        for service in ['Documents','Reports']:
            task = f'workspace/{run}/{service}'
            start = emit(task,'Alice',service,'start',[parent])
            a = emit(task,'Alice','TGS','TGS-REQ',[start,login])
            a = emit(task,'TGS','Alice','TGS-REP',[a])
            a = emit(task,'Alice',service,'AP-REQ',[a])
            a = emit(task,service,'Alice','AP-REP',[a])
            leaves = []
            for child in (['metadata','content'] if service == 'Documents' else ['report1','report2']):
                sub = task+'/'+child
                begin = emit(sub,'Alice',service,'start',[a])
                dependencies = [begin]
                if service == 'Reports':
                    dependencies = []
                    for part in ['data','template']:
                        p = emit(sub+'/'+part,service,'Backend', 'request',[begin])
                        p = emit(sub+'/'+part,'Backend',service,'complete',[p])
                        dependencies.append(p)
                end = emit(sub,service,'Alice','complete',[begin,*dependencies])
                leaves.append(end)
            end = emit(task,service,'Alice','complete',[start,*leaves])
            end = emit(task,service,'Audit','audit',[end])
            ends.append(end)
        login = emit(f'workspace/{run}','Workspace','Alice','complete',[parent,*ends])
    # Display a topological interleaving, retaining only declared ordering edges.
    depths = {}
    for event in events:
        depths[event['id']] = 1 + max((depths[p] for p in event['prior']), default=-1)
    return sorted(events, key=lambda e: (depths[e['id']], e['id']))


class KerberosVideo(Scene):
    def construct(self):
        self.camera.background_color = BG
        timings = json.loads((ROOT/'timings.json').read_text())
        narration = json.loads((ROOT/'narration.json').read_text())
        events = trace()
        (ROOT/'events.json').write_text(json.dumps(events,indent=2)+'\n')
        slides = {
            'intro': ('Kerberos: time, knowledge, and obligation', ['Alice → AS / TGS → Documents + Reports', 'Legal futures • indistinguishable histories • ideal futures', 'Symbolic model: uncompromised keys', 'Extended modalities: explicit example semantics']),
            'keys': ('Who can derive which key?', ['Alice ↔ AS: long-term client key', 'TGS ↔ KDC: ticket-granting key', 'Documents ↔ KDC: Documents key', 'Reports ↔ KDC: Reports key', 'AS-REP: encrypted TGT + protected client/TGS key', 'Carrying a ticket ≠ decrypting it']),
            'exchange': ('One service authentication exchange', ['Alice → TGS: TGS-REQ(TGT, authenticator, service)', 'TGS → Alice: TGS-REP(ticket, protected session key)', 'Alice → Documents: AP-REQ(ticket, fresh authenticator)', 'Documents → Alice: AP-REP for mutual authentication', 'Validate binding + lifetime + freshness + replay cache', 'Application authorization is a separate policy']),
            'knowledge': ('Quantify over actor-local alternatives', ['h ~ₐ h′  ⇔  obsₐ(h) = obsₐ(h′)', 'Kₐ φ(h) ⇔ ∀h′ ∈ W. (h ~ₐ h′ → φ(h′))', '∀ indistinguishable histories: the claim must hold', 'Derives(Alice, k)     Derives(Documents, k)', '¬Derives(Observer, k): symbolic encryption assumption', 'Key possession ≠ knowledge of origin or peer participation']),
            'past': ('Past evidence becomes forward monitor state', ['Previously issued(t) ⇔ ∃ matching ancestor issuance', 'issuedBefore₀ = ∅', 'issuedBeforeᵢ₊₁ = issuedBeforeᵢ ∪ issuedAtᵢ', 'AG(accepted(t) → t ∈ issuedBefore)', 'Evaluate before consuming the current event', 'Preserve ticket ID, task scope, and ancestry']),
            'obligation': ('Duty and enforcement quantify differently', ['Oₛ ψ(h) ⇔ ∀π ∈ Idealₛ(h). ψ(π)', 'Pₛ ψ(h) ⇔ ∃π ∈ Idealₛ(h). ψ(π)', 'Oₛ F audit(r) ⇔ ∀π ∈ Idealₛ(h). ∃i ≥ 0. audit(r, πᵢ)', 'Actual guarantee: AF audit(r)', 'Counterexample: EG ¬audit(r)', 'Nonempty ideal futures; audit is application policy']),
            'finish': ('Three relations; one protocol history', ['Temporal: legal continuations from the selected prefix', 'Epistemic: actor-local indistinguishability', 'Deontic: explicitly policy-compliant futures', 'AG(accepted(r) → Kₛ binding(r))', 'AG(accepted(r) → Oₛ F audit(r))', 'AG(accepted(r) → AF audit(r))', 'Candidate obligations require separate model proofs'])
        }
        for chapter in narration:
            key = chapter['id']
            start = self.time
            if key == 'trace':
                self.trace_scene(events)
            elif key == 'intro':
                heading = Text('Kerberos: time, knowledge, and obligation',font_size=32).to_edge(UP)
                selected = [e for e in events if e['task']=='login' or
                            (e['task'] in ('workspace/0/Documents','workspace/0/Reports') and
                             e['message'] in ('TGS-REQ','TGS-REP','AP-REQ','AP-REP'))]
                diagram = self.interaction(selected,['Alice','AS','TGS','Documents','Reports'])
                diagram.scale(.75).shift(UP*.45)
                notes = VGroup(
                    Text('Temporal futures • actor-local histories • policy-compliant futures',font_size=21,color=GOLD),
                    Text('Symbolic model: uncompromised keys',font_size=20,color=GREEN),
                    Text('Required at acceptance: credential binding and eventual audit',font_size=20,color=BLUE),
                ).arrange(DOWN,buff=.18).to_edge(DOWN,buff=.22)
                self.play(FadeIn(heading),FadeIn(diagram),run_time=2)
                self.play(FadeIn(notes))
            elif key in ('keys', 'exchange'):
                selected = [e for e in events if e['task'] == ('login' if key == 'keys' else 'workspace/0/Documents')
                            and e['message'] in ('AS-REQ','AS-REP','TGS-REQ','TGS-REP','AP-REQ','AP-REP')]
                title = 'Authentication service: obtaining the TGT' if key == 'keys' else 'Ticket and mutual-authentication exchanges'
                diagram = self.interaction(selected, ['Alice','AS'] if key == 'keys' else ['Alice','TGS','Documents'])
                diagram.scale(.82).shift(UP*.4)
                self.play(FadeIn(Text(title,font_size=32).to_edge(UP)), FadeIn(diagram),run_time=2)
                note = 'AS-REP: TGT encrypted for TGS; session key protected for Alice' if key == 'keys' else 'Ticket + fresh authenticator → validation → mutual authentication'
                notes = VGroup(Text(note,font_size=21,color=GOLD),
                    Text('Required after validation: Kₛ binding(r) ∧ Oₛ F audit(r)' if key=='exchange'
                         else 'After receipt and decryption: Alice derives the client/TGS key',font_size=21,color=GREEN),
                    Text('Assertions depend on the stated model assumptions; no proof claimed',font_size=17,color=WHITE)
                ).arrange(DOWN,buff=.18).to_edge(DOWN,buff=.18)
                self.play(FadeIn(notes))
            else:
                title, lines = slides[key]
                heading = Text(title,font='DejaVu Sans',font_size=34).to_edge(UP)
                if heading.width > 12.8: heading.scale_to_fit_width(12.8)
                rows = VGroup(*[Text(line,font='DejaVu Sans',font_size=25,color=[BLUE,GREEN,GOLD,WHITE][i%4]) for i,line in enumerate(lines)])
                for row in rows:
                    if row.width > 12.3: row.scale_to_fit_width(12.3)
                rows.arrange(DOWN,buff=.36).shift(DOWN*.15)
                self.play(FadeIn(heading),LaggedStart(*[FadeIn(row,shift=RIGHT*.2) for row in rows],lag_ratio=.3),run_time=3)
            self.wait(max(.1,timings[key]-.55-(self.time-start)))
            self.play(*[FadeOut(m) for m in list(self.mobjects)],run_time=.55)

    def trace_scene(self, events):
        heading = Text('Nested tasks in a long immutable trace',font_size=34).to_edge(UP)
        caption = Text('workspace → Documents(metadata, content) + Reports(report(data, template))',font_size=20,color=GOLD).to_edge(DOWN)
        self.add(heading,caption)
        panel = None
        for offset in [0,12,24,36,48,60,72,48,24,0]:
            rows = []
            for e in events[offset:offset+10]:
                text = f"{e['id']}  {e['task']}  {e['message']}  prior=[{','.join(e['prior'])}]"
                row = Text(text,font='DejaVu Sans Mono',font_size=15,color=GREEN if e['message']=='complete' else BLUE)
                if row.width>6.1: row.scale_to_fit_width(6.1)
                rows.append(row)
            log = VGroup(*rows).arrange(DOWN,aligned_edge=LEFT,buff=.23).move_to(LEFT*3.35)
            diagram = self.interaction(events[offset:offset+10], ['Alice','TGS','Documents','Reports','Backend','Audit','Workspace','AS'], compact=True)
            diagram.scale(.48).move_to(RIGHT*3.3)
            new = VGroup(log,diagram)
            if panel is None: self.play(FadeIn(new))
            else: self.play(FadeOut(panel,shift=UP*.3),FadeIn(new,shift=DOWN*.3),run_time=.6)
            panel = new
            self.wait(1.4)

    def interaction(self, events, actors, compact=False):
        """Project the selected event records onto actor lifelines."""
        xs = {a: -5.7 + i*11.4/max(1,len(actors)-1) for i,a in enumerate(actors)}
        result = VGroup()
        for actor in actors:
            name = Text(actor,font='DejaVu Sans',font_size=16 if compact else 23,color=WHITE)
            name.move_to([xs[actor],2.5,0])
            result.add(name,DashedLine([xs[actor],2.15,0],[xs[actor],-2.6,0],color='#64748b',stroke_width=1.5))
        annotations = {'AS-REQ':'AS-REQ(client, realm)', 'AS-REP':'AS-REP(TGT, protected key)',
                       'TGS-REQ':'TGS-REQ(TGT, authenticator, service)', 'TGS-REP':'TGS-REP(ticket, protected key)',
                       'AP-REQ':'AP-REQ(ticket, authenticator)', 'AP-REP':'AP-REP(mutual authentication)'}
        for i,event in enumerate(events):
            y = 1.75-i*4.0/max(1,len(events)-1)
            src,dst = xs[event['src']],xs[event['dst']]
            color = GREEN if event['message'] in ('complete','audit','AP-REP') else BLUE
            arrow = Arrow([src,y,0],[dst,y,0],buff=.06,color=color,stroke_width=2,max_tip_length_to_length_ratio=.12)
            label = Text(event['id']+' '+(event['message'] if compact else annotations.get(event['message'],event['message'])),
                         font_size=13 if compact else 20,color=color)
            if label.width>10: label.scale_to_fit_width(10)
            label.move_to([(src+dst)/2,y+.14,0])
            result.add(arrow,label)
        return result
