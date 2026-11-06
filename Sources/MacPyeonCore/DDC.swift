import Foundation

/// DDC/CI(모니터 케이블로 모니터 설정을 바꾸는 표준) 패킷 만들기·읽기.
/// 모니터 주소 0x37 에 보내며, 첫 바이트(보내는 쪽 주소 0x51)는 I2C 호출의 오프셋으로 따로 넘긴다.
public enum DDC {
    public static let brightness: UInt8 = 0x10
    static let destination: UInt8 = 0x6E
    static let source: UInt8 = 0x51

    private static func checksum(_ bytes: [UInt8]) -> UInt8 {
        bytes.reduce(destination ^ source, ^)
    }

    /// VCP 값 읽기 요청. (길이 0x82, 명령 0x01, VCP 코드, 검사합)
    public static func getPacket(_ vcp: UInt8) -> [UInt8] {
        let body: [UInt8] = [0x82, 0x01, vcp]
        return body + [checksum(body)]
    }

    /// VCP 값 쓰기 요청. (길이 0x84, 명령 0x03, VCP 코드, 값 상위, 값 하위, 검사합)
    public static func setPacket(_ vcp: UInt8, value: UInt16) -> [UInt8] {
        let body: [UInt8] = [0x84, 0x03, vcp, UInt8(value >> 8), UInt8(value & 0xFF)]
        return body + [checksum(body)]
    }

    /// 읽기 응답에서 (현재 값, 최대 값)을 꺼낸다. 응답 형식: … 02 결과(00) VCP 종류 최대(2) 현재(2) …
    public static func parseReply(_ reply: [UInt8], vcp: UInt8) -> (current: UInt16, max: UInt16)? {
        guard reply.count >= 8 else { return nil }
        for i in 0..<(reply.count - 7) where reply[i] == 0x02 && reply[i + 1] == 0x00 && reply[i + 2] == vcp {
            let maxValue = UInt16(reply[i + 4]) << 8 | UInt16(reply[i + 5])
            let current = UInt16(reply[i + 6]) << 8 | UInt16(reply[i + 7])
            guard maxValue > 0, current <= maxValue else { continue }
            return (current, maxValue)
        }
        return nil
    }

    /// 레지스트리의 "EDID UUID"(예: 2E830032-…)에서 제조사·모델 번호를 꺼낸다.
    /// 모델 번호는 EDID에 리틀 엔디언으로 들어 있어 바이트 순서를 뒤집는다.
    public static func vendorAndModel(fromEDIDUUID uuid: String) -> (vendor: UInt32, model: UInt32)? {
        let hex = uuid.replacingOccurrences(of: "-", with: "")
        guard hex.count >= 8,
              let vendor = UInt32(hex.prefix(4), radix: 16),
              let modelLE = UInt32(hex.dropFirst(4).prefix(4), radix: 16) else { return nil }
        let model = ((modelLE & 0xFF) << 8) | (modelLE >> 8)
        return (vendor, model)
    }
}
