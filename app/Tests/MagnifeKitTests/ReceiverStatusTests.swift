import Foundation
import Testing
@testable import MagnifeKit

/// The receiver's words in the toolbar and the busy-port banner (S-001, S-002).
@Suite("ReceiverStatus")
struct ReceiverStatusTests {
    private func ports(_ grpc: PortStatus.State, _ http: PortStatus.State,
                       grpcOwner: String? = nil, httpOwner: String? = nil) -> ReceiverStatus {
        .ports(ReceiverPorts(grpc: PortStatus(addr: "127.0.0.1:4317", state: grpc, owner: grpcOwner),
                             http: PortStatus(addr: "127.0.0.1:4318", state: http, owner: httpOwner)))
    }

    @Test("starting shows nothing for half a second, then \"Starting receiver…\"")
    func quietStart() {
        #expect(ReceiverStatus.starting.statusText(startingFor: 0) == nil)
        #expect(ReceiverStatus.starting.statusText(startingFor: 0.49) == nil)
        #expect(ReceiverStatus.starting.statusText(startingFor: 0.5) == "Starting receiver…")
        #expect(ReceiverStatus.starting.statusText(startingFor: 3) == "Starting receiver…")
        // A state the helper reported shows at once.
        #expect(ports(.listening, .listening).statusText(startingFor: 0) == "Receiving on 4317 and 4318")
        #expect(ReceiverStatus.stopped("missing").statusText(startingFor: 0) == "Not receiving")
    }

    @Test("no banner while both ports listen")
    func noBanner() {
        #expect(ports(.listening, .listening).busyBanner == nil)
        #expect(ReceiverStatus.starting.busyBanner == nil)
        #expect(ReceiverStatus.stopped("x").busyBanner == nil)
    }

    @Test("one busy port names it and its owner", arguments: [
        (PortStatus.State.listening, PortStatus.State.busy, "otelcol-contrib", "Port 4318 is in use by otelcol-contrib. Quit that app, then click Try Again."),
        (.busy, .listening, "otelcol-contrib", "Port 4317 is in use by otelcol-contrib. Quit that app, then click Try Again."),
        (.listening, .busy, nil, "Port 4318 is in use by another app. Quit that app, then click Try Again."),
        (.busy, .listening, "", "Port 4317 is in use by another app. Quit that app, then click Try Again."),
    ] as [(PortStatus.State, PortStatus.State, String?, String)])
    func oneBusy(grpc: PortStatus.State, http: PortStatus.State, owner: String?, banner: String) {
        let status = ports(grpc, http, grpcOwner: grpc == .busy ? owner : nil, httpOwner: http == .busy ? owner : nil)
        #expect(status.busyBanner == banner)
        #expect(status.isReceiving)
        #expect(status.text == (grpc == .busy ? "Receiving on 4318 only" : "Receiving on 4317 only"))
    }

    @Test("both busy: one banner naming both ports, \"Not receiving\"")
    func bothBusy() {
        let status = ports(.busy, .busy, grpcOwner: "otelcol-contrib", httpOwner: "jaeger")
        #expect(status.busyBanner == "Ports 4317 and 4318 are in use by other apps. Quit them, then click Try Again.")
        #expect(status.text == "Not receiving")
        #expect(!status.isReceiving)
    }

    @Test("an unknown state counts as busy, so it is never shown as receiving")
    func otherState() {
        let status = ports(.listening, .other("failed"))
        #expect(status.text == "Receiving on 4317 only")
        #expect(status.busyBanner == "Port 4318 is in use by another app. Quit that app, then click Try Again.")
    }

    @Test("the tooltip names the reported ports, else the configured ones")
    func tooltip() {
        #expect(ReceiverStatus.starting.tooltip(grpcPort: 4317, httpPort: 4318)
                == "Magnife accepts OTLP over gRPC on 4317 and HTTP on 4318")
        let custom = ReceiverStatus.ports(ReceiverPorts(grpc: PortStatus(addr: "127.0.0.1:14317", state: .listening),
                                                        http: PortStatus(addr: "127.0.0.1:14318", state: .busy)))
        #expect(custom.tooltip(grpcPort: 4317, httpPort: 4318) == "Magnife accepts OTLP over gRPC on 14317 and HTTP on 14318")
    }

    @Test("the helper's error line reads as a receiver problem")
    func problem() {
        #expect(ReceiverStatus.problem("open database: disk I/O error")
                == "The receiver reported a problem: open database: disk I/O error")
    }
}
