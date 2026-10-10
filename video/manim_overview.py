import json
from pathlib import Path

from manim import *

HERE = Path(__file__).parent
TIMINGS = json.loads((HERE / "timings.json").read_text()) if (HERE / "timings.json").exists() else {}
BG, PANEL = "#111111", "#1f2937"
BLUE, GREEN, AMBER, RED, MUTED = "#60a5fa", "#4ade80", "#fbbf24", "#f87171", "#b7c0cc"


class LeanFMOverview(Scene):
    def construct(self):
        self.camera.background_color = BG
        scenes = [("thesis", self.thesis_scene), ("alphabet", self.alphabet_scene),
                  ("grammar", self.grammar_scene), ("transition_system", self.transition_scene),
                  ("ctl_coordinates", self.ctl_scene), ("requirements", self.requirements_scene),
                  ("duality", self.duality_scene), ("diffie_hellman", self.diffie_hellman_scene),
                  ("modal_reading", self.modal_scene), ("conclusion", self.conclusion_scene)]
        for key, builder in scenes:
            start = self.time
            builder()
            self.wait(max(.1, TIMINGS.get(key, 24) - .55 - (self.time - start)))
            self.play(*[FadeOut(m) for m in list(self.mobjects)], run_time=.55)

    def heading(self, text):
        return Text(text, font_size=38, color=WHITE, font="DejaVu Sans").to_edge(UP)

    def box(self, text, color=BLUE, width=2.5, height=.75, size=21):
        rect = RoundedRectangle(width=width, height=height, corner_radius=.12,
                                color=color, fill_color=PANEL, fill_opacity=1)
        label = Text(text, font_size=size, color=WHITE, font="DejaVu Sans")
        if label.width > width - .25:
            label.scale_to_fit_width(width - .25)
        return VGroup(rect, label)

    def thesis_scene(self):
        title = Text("LeanFM", font_size=68, color=WHITE)
        sub = Text("from protobuf messages to CTL requirements", font_size=32, color=BLUE).next_to(title, DOWN)
        layers = VGroup(*[self.box(x, c, width=3.25) for x, c in [
            ("typed protobuf values", BLUE), ("legal actor grammar", AMBER),
            ("branching transition system", GREEN), ("CTL constraints", RED)
        ]]).arrange(RIGHT, buff=.18).scale(.8).to_edge(DOWN, buff=1)
        arrows = VGroup(*[Arrow(layers[i].get_right(), layers[i+1].get_left(), buff=.05, color=MUTED) for i in range(3)])
        self.play(Write(title), FadeIn(sub, shift=UP), run_time=1.4)
        self.play(LaggedStart(*[FadeIn(x, shift=RIGHT) for x in layers], lag_ratio=.2),
                  LaggedStart(*[GrowArrow(x) for x in arrows], lag_ratio=.2), run_time=2.5)

    def alphabet_scene(self):
        head = self.heading("1. Define the byte-level message alphabet")
        proto = VGroup(Text("RequirementEnvelope", font_size=28), Text("oneof atom", font_size=25, color=AMBER),
                       Text("1  Docs.GetRequest", font_size=22, color=BLUE),
                       Text("2  Docs.FetchCommand", font_size=22, color=BLUE),
                       Text("3  Docs.FetchResult200", font_size=22, color=GREEN),
                       Text("4  Docs.FetchResult404", font_size=22, color=RED)).arrange(DOWN, aligned_edge=LEFT, buff=.18)
        proto_group = VGroup(SurroundingRectangle(proto, color=BLUE, buff=.3, corner_radius=.12), proto).shift(LEFT*3)
        atom = self.box("Gateway → Worker\nDocs.FetchCommand\ntask = get_docs", AMBER, 4.2, 1.7, 25).shift(RIGHT*3)
        eq = Text("atom = (task, source, destination, message)", font_size=26).to_edge(DOWN, buff=.7)
        self.play(FadeIn(head), FadeIn(proto_group, shift=RIGHT), run_time=1.5)
        self.play(TransformFromCopy(proto[3], atom), Write(eq), run_time=2)
        badge = Text("valid bytes  ≠  legal protocol event", font_size=29, color=RED).next_to(atom, DOWN, buff=.45)
        self.play(FadeIn(badge, shift=UP))

    def grammar_scene(self):
        head = self.heading("2. Compose atoms into a multiparty grammar")
        actors = VGroup(*[self.box(x, BLUE, 2.1) for x in ["Client", "Gateway", "Worker"]]).arrange(RIGHT, buff=2).shift(UP*1.8)
        c, g, w = actors
        specs = [(c,g,"GetRequest",BLUE), (g,w,"FetchCommand",AMBER),
                 (w,g,"Result200 | Result404",GREEN), (g,c,"Response | Error",BLUE)]
        arrows = VGroup()
        for (src,dst,label,color), y in zip(specs, [.65,-.1,-.85,-1.6]):
            a = Arrow([src.get_x(),y,0], [dst.get_x(),y,0], buff=.12, color=color)
            arrows.add(VGroup(a, Text(label, font_size=20).next_to(a, UP, buff=.08)))
        grammar = Text("seq(GetRequest, alt(Error, seq(FetchCommand, alt(Success, NotFound))))",
                       font_size=22, color=AMBER).to_edge(DOWN, buff=.32)
        self.play(FadeIn(head), FadeIn(actors))
        self.play(LaggedStart(*[GrowArrow(x[0]) for x in arrows], lag_ratio=.35),
                  LaggedStart(*[FadeIn(x[1]) for x in arrows], lag_ratio=.35), run_time=4)
        self.play(Write(grammar), run_time=2)
        self.play(FadeIn(Text("✓ declared constructor and order", font_size=24, color=GREEN).shift(LEFT*3+DOWN*2.45)),
                  FadeIn(Text("✗ result before command", font_size=24, color=RED).shift(RIGHT*3+DOWN*2.45)))

    def transition_scene(self):
        head = self.heading("3. Legal trace prefixes generate the state graph")
        pos = {"s₀":LEFT*4.8+UP*.8, "request":LEFT*2.7+UP*.8, "reject":LEFT*.4+UP*2,
               "fetch":LEFT*.4+DOWN*.35, "200":RIGHT*2.1+UP*.7, "404":RIGHT*2.1+DOWN*1.25,
               "done":RIGHT*4.8+UP*.7, "failed":RIGHT*4.8+DOWN*1.25}
        nodes = {k:self.box(k, GREEN if k=="done" else RED if k=="failed" else BLUE, 1.45,.62,21).move_to(v) for k,v in pos.items()}
        pairs = [("s₀","request"),("request","reject"),("request","fetch"),("reject","failed"),
                 ("fetch","200"),("fetch","404"),("200","done"),("404","failed")]
        arrows = [Arrow(nodes[a].get_right(), nodes[b].get_left(), buff=.06, color=MUTED, stroke_width=3) for a,b in pairs]
        self.play(FadeIn(head), FadeIn(nodes["s₀"]))
        self.play(LaggedStart(*[FadeIn(n) for k,n in nodes.items() if k!="s₀"], lag_ratio=.12),
                  LaggedStart(*[GrowArrow(a) for a in arrows], lag_ratio=.12), run_time=4)
        caption = Text("Paths(s) = all permitted futures from legal prefix s", font_size=28, color=AMBER).to_edge(DOWN, buff=.4)
        self.play(Write(caption))
        for name in ["reject","404","failed"]: self.play(Indicate(nodes[name], color=RED), run_time=.7)

    def ctl_scene(self):
        head = self.heading("4. CTL quantifies over paths and positions")
        rows = [("EF p","∃ π ∈ Paths(s).  ∃ i ≥ 0.  p(πᵢ)",BLUE),
                ("AF p","∀ π ∈ Paths(s).  ∃ i ≥ 0.  p(πᵢ)",AMBER),
                ("EG p","∃ π ∈ Paths(s).  ∀ i ≥ 0.  p(πᵢ)",GREEN),
                ("AG p","∀ π ∈ Paths(s).  ∀ i ≥ 0.  p(πᵢ)",RED)]
        table = VGroup(*[VGroup(Text(a,font_size=38,color=c), Text(b,font_size=28)).arrange(RIGHT,buff=.7) for a,b,c in rows])
        table.arrange(DOWN, aligned_edge=LEFT, buff=.58).shift(DOWN*.15)
        self.play(FadeIn(head))
        self.play(LaggedStart(*[FadeIn(row, shift=RIGHT) for row in table], lag_ratio=.3), run_time=4)
        notes = VGroup(Text("E / A choose paths", font_size=24, color=BLUE),
                       Text("F / G choose positions", font_size=24, color=GREEN)).arrange(RIGHT,buff=2).to_edge(DOWN,buff=.25)
        self.play(FadeIn(notes))
        for row in table: self.play(Indicate(row, scale_factor=1.03), run_time=.8)

    def requirement_card(self, formula, gloss, color):
        rect = RoundedRectangle(width=5.7,height=1.7,corner_radius=.15,color=color,fill_color=PANEL,fill_opacity=1)
        f = Text(formula,font_size=30,color=color)
        if f.width > 5.2:
            f.scale_to_fit_width(5.2)
        g = Text(gloss,font_size=21).next_to(f,DOWN,buff=.22)
        return VGroup(rect,f,g)

    def requirements_scene(self):
        head = self.heading("5. State constraints over the generated futures")
        cards = VGroup(self.requirement_card("AG(authenticated ∨ ¬success)","safety: no unauthenticated success",RED),
                       self.requirement_card("AF terminal","liveness: every future terminates",AMBER),
                       self.requirement_card("EF not_found","existence: retain a failure witness",BLUE),
                       self.requirement_card("EG within_bound","viability: some invariant future",GREEN))
        cards.arrange_in_grid(rows=2,cols=2,buff=(.55,.55)).shift(DOWN*.25)
        self.play(FadeIn(head), LaggedStart(*[FadeIn(c,shift=UP) for c in cards],lag_ratio=.3),run_time=4)
        for card in cards: self.play(Indicate(card[1],color=card[1].get_color()),run_time=.8)

    def duality_scene(self):
        head = self.heading("6. Universal checking becomes witness search")
        safety = Text("AG p  ⇔  ¬ EF ¬p",font_size=50,color=GREEN).shift(UP*1.35)
        sr = Text("no reachable counterexample to p",font_size=27).next_to(safety,DOWN,buff=.25)
        live = Text("AF p  ⇔  ¬ EG ¬p",font_size=50,color=BLUE).shift(DOWN*.6)
        lr = Text("no path or cycle where ¬p persists",font_size=27).next_to(live,DOWN,buff=.25)
        search = self.box("∃ witness search",AMBER,3.4,.9,28).to_edge(DOWN,buff=.35)
        self.play(FadeIn(head),Write(safety),FadeIn(sr),run_time=2.5)
        self.play(Write(live),FadeIn(lr),run_time=2.5)
        self.play(FadeIn(search,shift=UP),Circumscribe(safety,color=GREEN),Circumscribe(live,color=BLUE),run_time=2)

    def cube(self, colors):
        cells = VGroup()
        for row in range(3):
            for col in range(3):
                cells.add(Square(.32, color=BG, fill_color=colors[(row*3+col)%len(colors)], fill_opacity=1)
                          .move_to([col*.32, -row*.32, 0]))
        return cells.move_to(ORIGIN)

    def diffie_hellman_scene(self):
        head = self.heading("7. Diffie–Hellman: messages first, security as theorems")
        names = VGroup(Text("Alice",font_size=30,color=BLUE), Text("NSA",font_size=30,color=RED),
                       Text("Bob",font_size=30,color=GREEN)).arrange(RIGHT,buff=4).shift(UP*1.8)
        alice, nsa, bob = names
        base_colors = [BLUE,GREEN,AMBER,RED,"#a78bfa",BLUE,GREEN,AMBER,RED]
        ca = self.cube(base_colors).scale(1.15).next_to(alice,DOWN,buff=.45)
        cb = self.cube(list(reversed(base_colors))).scale(1.15).next_to(bob,DOWN,buff=.45)
        dice_a = self.box("private a ∈ {1,…,6}",BLUE,2.7,.65,20).next_to(ca,DOWN,buff=.25)
        dice_b = self.box("private b ∈ {1,…,6}",GREEN,2.7,.65,20).next_to(cb,DOWN,buff=.25)
        public = Text("public initial cube C₀ and move M",font_size=25,color=AMBER).to_edge(DOWN,buff=.35)
        self.play(FadeIn(head),FadeIn(names),FadeIn(ca),FadeIn(cb),FadeIn(dice_a),FadeIn(dice_b),Write(public),run_time=3)
        exchange_a = CurvedArrow(ca.get_right(),cb.get_left(),angle=-.35,color=BLUE)
        exchange_b = CurvedArrow(cb.get_left(),ca.get_right(),angle=-.35,color=GREEN)
        seen = Text("NSA relays Mᵃ(C₀) and Mᵇ(C₀)",font_size=25,color=RED).next_to(nsa,DOWN,buff=.65)
        self.play(Create(exchange_a),Create(exchange_b),FadeIn(seen),run_time=2)
        toy = Text("Mᵃ(Mᵇ(C₀)) = Mᵇ(Mᵃ(C₀)) = Mᵃ⁺ᵇ(C₀)",font_size=31,color=WHITE).shift(DOWN*1.5)
        warning = Text("toy only: six rolls are enumerable; exponents add",font_size=25,color=RED).next_to(toy,DOWN,buff=.28)
        self.play(Write(toy),FadeIn(warning),run_time=2.5)
        self.wait(2)
        self.play(*[FadeOut(m) for m in [ca,cb,dice_a,dice_b,public,exchange_a,exchange_b,seen,toy,warning]],run_time=1)
        equations = VGroup(Text("A = gᵃ mod p",font_size=38,color=BLUE),
                           Text("B = gᵇ mod p",font_size=38,color=GREEN),
                           Text("K = Bᵃ = Aᵇ = gᵃᵇ mod p",font_size=42,color=AMBER)).arrange(DOWN,buff=.45).shift(UP*.15)
        visible = Text("NSA observes:  p, g, A, B",font_size=27,color=RED).next_to(equations,DOWN,buff=.5)
        hard = Text("assumption: discrete logarithms are hard in the chosen group",font_size=24,color=WHITE).next_to(visible,DOWN,buff=.25)
        self.play(LaggedStart(*[Write(e) for e in equations],lag_ratio=.5),run_time=4)
        self.play(FadeIn(visible),FadeIn(hard))
        cipher1 = CurvedArrow(alice.get_bottom(),bob.get_bottom(),angle=-.25,color=BLUE)
        cipher2 = CurvedArrow(bob.get_bottom(),alice.get_bottom(),angle=-.25,color=GREEN)
        label = Text("KDF → directional keys; authenticated encryption + distinct nonces",font_size=22,color=WHITE).to_edge(DOWN,buff=.18)
        self.play(Create(cipher1),Create(cipher2),FadeIn(label),run_time=2)
        theorem = Text("grammar: public messages     theorems: secrecy • agreement • freshness • authentication",
                       font_size=21,color=AMBER).next_to(head,DOWN,buff=.22)
        self.play(FadeIn(theorem))

    def conclusion_scene(self):
        head = self.heading("One observable language; three levels of precision")
        labels = [("protobuf","which values resolve to bytes",BLUE),
                  ("grammar","which actor conversations are legal",AMBER),
                  ("CTL + Lean","what every—or some—legal future must satisfy",GREEN)]
        cards = VGroup()
        for name,gloss,color in labels:
            rect=RoundedRectangle(width=10.5,height=1.25,corner_radius=.14,color=color,fill_color=PANEL,fill_opacity=1)
            lhs = Text(name,font_size=32,color=color).move_to([rect.get_left()[0]+1.7, rect.get_y(), 0])
            rhs = Text(gloss,font_size=24).move_to([rect.get_left()[0]+6.7, rect.get_y(), 0])
            if rhs.width > 6.1:
                rhs.scale_to_fit_width(6.1)
            cards.add(VGroup(rect,lhs,rhs))
        cards.arrange(DOWN,buff=.45).shift(DOWN*.2)
        self.play(FadeIn(head),LaggedStart(*[FadeIn(c,shift=RIGHT) for c in cards],lag_ratio=.3),run_time=4)
        self.play(Write(Text("counterexample = concrete legal witness",font_size=29,color=RED).to_edge(DOWN,buff=.22)))

    def modal_scene(self):
        head = self.heading("Modal language becomes explicit requirements")
        lines = VGroup(
            Text("possibly p:  EF p     necessarily p:  AG p", font_size=30,color=BLUE),
            Text("present and future:  positions i ≥ 0",font_size=27,color=WHITE),
            Text("eventually: AF p     invariant: AG p",font_size=29,color=AMBER),
            Text("AF p ⇔ ¬ EG ¬p",font_size=35,color=GREEN),
            Text("Kₐ p: knows     Bₐ p: believes",font_size=27,color=WHITE),
            Text("Pₐ p: permitted     Oₐ p: obligatory",font_size=27,color=WHITE),
            Text("Additional modalities require explicit semantics",font_size=23,color=RED),
        ).arrange(DOWN,buff=.32)
        self.play(FadeIn(head),LaggedStart(*[FadeIn(line) for line in lines],lag_ratio=.25),run_time=4)
