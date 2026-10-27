// Ported from deckcraft crates/anim/src/transition_tests.rs (transition curves and geometry against values
// measured on PowerPoint's video export, 2 s transitions at 30 fps), the tests in mesh.rs and the preset
// path test in path.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
import DCModel
import Testing
@testable import DCAnim

private let A = 16.0 / 9.0

private func near(_ a: Double, _ b: Double, _ tol: Double) -> Bool { Swift.abs(a - b) <= tol }

private func of(_ ls: [Layer], _ src: Source) -> [Layer] { ls.filter { $0.source == src } }

private func left(_ l: Layer) -> Double { l.quad.corners.map { $0[0] }.reduce(Double.infinity) { $0.rustMin($1) } }

private func top(_ l: Layer) -> Double { l.quad.corners.map { $0[1] }.reduce(Double.infinity) { $0.rustMin($1) } }

@Suite struct TransitionCurveTests {
    @Test func fadeFollowsPowerpointsSCurve() throws {
        // Measured share of the new slide in a 2 s Fade at t = 0.25, 0.5, 0.75: 0.155, 0.49, 0.82.
        for (t, want) in [(0.25, 0.155), (0.5, 0.49), (0.75, 0.82)] {
            let new = of(transitionLayers("fade", "smoothly", t), .new)
            let a = try #require(new.first?.alpha)
            #expect(near(a, want, 0.04), "t=\(t): \(a)")
        }
        // Through black: the old slide is gone to black at the middle, then the new one fades in.
        #expect(transitionLayers("fade", "throughBlack", 0.5).allSatisfy { $0.source == .black })
        let q = transitionLayers("fade", "throughBlack", 0.25)
        #expect(near(of(q, .old).first?.alpha ?? .nan, 0.5, 0.01))
    }

    @Test func pushMovesBothSlidesWithAnEasedCurve() throws {
        for (o, dx, dy) in [("l", -1.0, 0.0), ("r", 1.0, 0.0), ("u", 0.0, -1.0), ("d", 0.0, 1.0)] {
            for t in [0.25, 0.5, 0.75] {
                let ls = transitionLayers("push", o, t)
                let old = try #require(of(ls, .old).first)
                let new = try #require(of(ls, .new).first)
                let s = q2(t)
                #expect(near(old.quad[0][0], dx * s, 1e-9) && near(old.quad[0][1], dy * s, 1e-9), "\(o) \(t)")
                #expect(near(new.quad[0][0], dx * (s - 1.0), 1e-9) && near(new.quad[0][1], dy * (s - 1.0), 1e-9), "\(o) \(t)")
            }
        }
        // Ease in-out: slow at both ends.
        #expect(q2(0.1) < 0.05 && q2(0.9) > 0.95 && near(q2(0.5), 0.5, 1e-9))
    }

    @Test func coverAndUncoverMatchMeasuredPositions() throws {
        // Offset of the new slide in Cover Left (fraction of the width) at measured times.
        for (t, off) in [(0.445, 0.655), (0.495, 0.512), (0.544, 0.359), (0.643, 0.134), (0.742, 0.046)] {
            let n = try #require(of(transitionLayers("cover", "l", t), .new).first)
            #expect(near(left(n), off, 0.05), "cover t=\(t)")
        }
        // Offset of the old slide in Uncover Left.
        for (t, off) in [(0.244, -0.06), (0.343, -0.14), (0.442, -0.32), (0.508, -0.5), (0.558, -0.63)] {
            let o = try #require(of(transitionLayers("uncover", "l", t), .old).first)
            #expect(near(left(o), off, 0.05), "uncover t=\(t)")
        }
        // Diagonal Cover shoots in and settles slowly.
        for (t, off) in [(0.142, 0.728), (0.257, 0.49), (0.356, 0.29), (0.455, 0.146), (0.604, 0.053)] {
            let n = try #require(of(transitionLayers("cover", "lu", t), .new).first)
            #expect(near(left(n), off, 0.06) && near(top(n), off, 0.06), "cover lu t=\(t)")
        }
        #expect(near(powInOut(0.25, 3.0), 0.0625, 1e-9))
    }

    @Test func wipeHasAWideSoftEdge() {
        // Measured along a row of Wipe Right at t = 0.5: about half-way through at x = 0.6, nearly nothing
        // at the right edge, fully new on the left third.
        let c = -0.4 + 1.8 * 1.05 * 0.5
        #expect(near(edge(c, 0.6, 0.8), 0.49, 0.1))
        #expect(edge(c, 1.0, 0.8) < 0.1)
        #expect(edge(c, 0.2, 0.8) > 0.8)
        // Directions: "r" starts on the left, "l" on the right, "u" at the bottom, "d" at the top, diagonals
        // at the opposite corner.
        func first(_ o: String) -> (Double, Double) {
            let n = of(transitionLayers("wipe", o, 0.15), .new)
            #expect(!n.isEmpty, "\(o)")
            let cx = n.map { ($0.quad[0][0] + $0.quad[2][0]) / 2.0 }.reduce(0.0, +) / Double(n.count)
            let cy = n.map { ($0.quad[0][1] + $0.quad[2][1]) / 2.0 }.reduce(0.0, +) / Double(n.count)
            return (cx, cy)
        }
        #expect(first("r").0 < 0.3 && first("l").0 > 0.7)
        #expect(first("u").1 > 0.7 && first("d").1 < 0.3)
        let ru = first("ru")
        #expect(ru.0 < 0.4 && ru.1 > 0.6, "\(ru)")
    }

    @Test func splitAndShapeOpenFromTheMiddle() {
        for o in ["horzOut", "vertOut"] {
            let n = of(transitionLayers("split", o, 0.2), .new)
            #expect(n.allSatisfy { l in
                let c = ((l.quad[0][0] + l.quad[2][0]) / 2.0, (l.quad[0][1] + l.quad[2][1]) / 2.0)
                return o.hasPrefix("horz") ? Swift.abs(c.1 - 0.5) < 0.4 : Swift.abs(c.0 - 0.5) < 0.4
            })
        }
        // Shape In is done with the old slide at half time; Shape Out starts the new one then.
        #expect(of(transitionLayers("shape", "in", 0.55), .old).isEmpty)
        #expect(of(transitionLayers("shape", "out", 0.45), .new).isEmpty)
    }

    @Test func dynamicContentCurves() throws {
        // Pan: the new content's offset (fraction of the width) at measured times.
        for (t, off) in [(0.6, 0.134), (0.7, 0.086), (0.8, 0.039), (0.9, 0.011)] {
            let n = try #require(of(transitionLayers("pan", "l", t), .newContent).first)
            #expect(near(left(n), off, 0.07), "pan t=\(t)")
        }
        // The backgrounds cross-fade under the moving contents.
        let ls = transitionLayers("pan", "l", 0.5)
        #expect(ls.first?.source == .oldBack)
        #expect((of(ls, .newBack).first?.alpha ?? 0) > 0.5)
        // Ferris Wheel: the old content drops (top edge, slide heights) as measured.
        for (t, dy) in [(0.147, 0.06), (0.246, 0.17), (0.345, 0.36), (0.444, 0.70)] {
            let q = try #require(of(transitionLayers("ferris", "l", t), .oldContent).first).quad
            let cy = q.corners.map { $0[1] }.reduce(0.0, +) / 4.0 - 0.5
            #expect(near(cy, dy, 0.08), "ferris t=\(t): \(cy)")
        }
        for k in ["pan", "ferris", "conveyor", "rotate", "window", "orbit", "flythrough"] {
            #expect(usesSlideParts(k, ""), "\(k)")
        }
        #expect(usesSlideParts("reveal", "smoothlyLeft") && !usesSlideParts("reveal", "blackLeft"))
        #expect(!usesSlideParts("cube", "l") && !usesSlideParts("push", "l"))
    }

    @Test func cubeTurnsTowardTheOption() throws {
        // Cube Left at the middle: the shared edge is near the middle, the old face on the left.
        let ls = transitionFrame("cube", "l", 0.5, A)
        let o = try #require(of(ls, .old).first)
        let n = try #require(of(ls, .new).first)
        let oRight = o.quad.corners.map { $0[0] }.reduce(-Double.infinity) { $0.rustMax($1) }
        #expect(near(oRight, left(n), 0.02), "shared edge: \(oRight) vs \(left(n))")
        #expect(oRight > 0.3 && oRight < 0.7)
        // Up: the new face comes from below.
        let up = transitionFrame("cube", "u", 0.5, A)
        let nu = try #require(of(up, .new).first)
        let ou = try #require(of(up, .old).first)
        #expect(top(nu) > top(ou))
    }

    @Test func switchSwapsTheCardsPastHalfway() {
        func order(_ t: Double) -> (Int?, Int?) {
            let ls = transitionFrame("switch", "l", t, A)
            return (ls.firstIndex { $0.source == .old }, ls.firstIndex { $0.source == .new })
        }
        let (o, n) = order(0.3)
        #expect((o ?? -1) > (n ?? -1), "old in front early")
        let (o2, n2) = order(0.8)
        #expect((n2 ?? -1) > (o2 ?? -1), "new in front late")
    }

    @Test func clockHandSweepsAtConstantSpeed() {
        // The share of the slide covered grows linearly.
        func area(_ t: Double) -> Double {
            of(transitionLayers("clock", "clockwise", t), .new).map { l in
                let (a, b, c) = (l.quad[0], l.quad[1], l.quad[2])
                return Swift.abs((b[0] - a[0]) * (c[1] - a[1]) - (c[0] - a[0]) * (b[1] - a[1])) / 2.0 * (l.fade[0] + l.fade[1] + l.fade[2]) / 3.0
            }.reduce(0.0, +)
        }
        let (a1, a2, a3) = (area(0.25), area(0.5), area(0.75))
        #expect(near(a2 - a1, a3 - a2, 0.08), "\(a1) \(a2) \(a3)")
        #expect(near(a2, 0.5, 0.08), "\(a2)")
    }

    @Test func optionsChangeTheFrame() {
        // Every option of a transition draws something different from its other options midway.
        for info in transitions where !["morph", "none", "random"].contains(info.id) && info.options.count >= 2 {
            for (i, a) in info.options.enumerated() {
                for b in info.options.dropFirst(i + 1) {
                    let differs = [0.2, 0.35, 0.5, 0.8].contains { transitionLayers(info.id, a, $0) != transitionLayers(info.id, b, $0) }
                    #expect(differs, "\(info.id): \(a) vs \(b)")
                }
            }
        }
    }

    @Test func framesStayCheap() {
        // Per frame, the show draws these meshes from cached slide textures: keep them small.
        for info in transitions {
            for o in info.options + [""] {
                for t in [0.1, 0.3, 0.5, 0.7, 0.9] {
                    let tris = transitionFrame(info.id, o, t, A).map { layerMesh($0).triangles.count }.reduce(0, +)
                    #expect(tris < 30_000, "\(info.id)/\(o) t=\(t): \(tris) triangles")
                }
            }
        }
    }

    @Test func hostileAspectsAreSafe() {
        for a in [Double.nan, 0.0, -3.0, 1e9, .infinity] {
            for info in transitions {
                for l in transitionFrame(info.id, "", 0.4, a) {
                    #expect(l.quad.corners.allSatisfy { $0[0].isFinite && $0[1].isFinite })
                    #expect((0 ..< 4).allSatisfy { (0.0 ... 1.0).contains(l.fade[$0]) })
                }
            }
        }
        #expect(near(ss(0.5), 0.5, 1e-12))
    }
}

@Suite struct MeshTests {
    @Test func rectIsTwoTriangles() {
        let (v, t) = layerMesh(Layer.full(.new, 1.0))
        #expect(v.count == 4 && t.count == 2)
    }

    @Test func trapezoidIsSubdividedProjectively() {
        // A card turned about its left edge: the right edge is shorter.
        let q = Quad(UnitPoint(0.0, 0.0), UnitPoint(0.6, 0.2), UnitPoint(0.6, 0.8), UnitPoint(0.0, 1.0))
        let l = Layer.quad(.old, SIMD4(0.0, 0.0, 1.0, 1.0), q, 1.0)
        let (v, t) = layerMesh(l)
        #expect(v.count == (meshGrid + 1) * (meshGrid + 1))
        #expect(t.count == meshGrid * meshGrid * 2)
        // A small tile in perspective needs no more than a couple of triangles.
        let small = Layer.quad(
            .old, SIMD4(0.0, 0.0, 1.0, 1.0),
            Quad(UnitPoint(0.5, 0.5), UnitPoint(0.52, 0.505), UnitPoint(0.52, 0.515), UnitPoint(0.5, 0.52)), 1.0
        )
        #expect(layerMesh(small).triangles.count <= 2)
        // Corners land on the quad's corners.
        #expect(v.first?.pos == q[0])
        let last = v.last?.pos ?? UnitPoint(.nan, .nan)
        #expect(Swift.abs(last[0] - 0.6) < 1e-9 && Swift.abs(last[1] - 0.8) < 1e-9)
        // The texture's middle column sits nearer the far (short) edge than halfway: foreshortening.
        let mid = v[meshGrid / 2].pos[0]
        #expect(mid > 0.3, "\(mid)")
    }

    @Test func degenerateQuadsDoNotBlowUp() {
        let p = UnitPoint(0.5, 0.5)
        let l = Layer.quad(.old, SIMD4(0.0, 0.0, 1.0, 1.0), Quad(p, p, p, p), 1.0)
        #expect(layerMesh(l).vertices.allSatisfy { $0.pos[0].isFinite && $0.pos[1].isFinite })
    }
}

@Suite struct PresetPathTests {
    @Test func everyExtraMotionPathPresetStartsAtItsShapeAndMoves() {
        let extra = animations.filter { $0.animClass == .path && presetPath($0.id) != nil }
        #expect(extra.count >= 30)
        for a in extra {
            #expect(defaultPath(a.id, "") == (presetPath(a.id) ?? ""))
            let mp = MotionPath.parse(defaultPath(a.id, ""))
            let (x, y) = mp.at(0.0)
            #expect(Swift.abs(x) < 1e-9 && Swift.abs(y) < 1e-9, "\(a.id) starts at its shape")
            let far = mp.points.map { Swift.abs($0.x) + Swift.abs($0.y) }.reduce(0.0) { $0.rustMax($1) }
            #expect(far > 0.05, "\(a.id) moves")
            #expect(mp.points.allSatisfy { Swift.abs($0.x) < 0.5 && Swift.abs($0.y) < 0.5 }, "\(a.id) stays near its shape")
        }
    }
}
