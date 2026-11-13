import Foundation
import Testing
@testable import ScreenHelmCore

@Suite struct DisplayCommandTests {
    @Test func aCommandLineIsRead() throws {
        let command = try DisplayCommand(arguments: ["set", "name=Studio Display", "brightness=0.6", "Volume=40%"])
        #expect(command.verb == .set)
        #expect(command.target == .name("Studio Display"))
        #expect(command.values.map(\.name) == ["brightness", "volume"])
        #expect(command.values.map(\.value) == ["0.6", "40%"])
    }

    @Test func thePointersDisplayIsTheDefaultTarget() throws {
        #expect(try DisplayCommand(arguments: ["toggle", "hdr"]).target == .pointer)
        #expect(try DisplayCommand(arguments: ["toggle", "display=main", "hdr"]).target == .main)
        #expect(try DisplayCommand(arguments: ["toggle", "display=Built-In", "xdr"]).target == .builtIn)
        #expect(try DisplayCommand(arguments: ["get", "display=all"]).target == .all)
        #expect(try DisplayCommand(arguments: ["get", "display=Dell"]).target == .name("Dell"))
        #expect(try DisplayCommand(arguments: ["get", "key=10ac-a0f1-00001234"]).target == .key("10ac-a0f1-00001234"))
        #expect(try DisplayCommand(arguments: ["perform", "group=Desk", "brightnessup"]).target == .group("Desk"))
    }

    @Test func theSameCommandFromAURLAndFromAnHTTPPath() throws {
        let typed = try DisplayCommand(arguments: ["set", "name=Studio", "brightness=0.6"])
        let url = try DisplayCommand(url: URL(string: "screenhelm://display/set?name=Studio&brightness=0.6")!)
        let http = try DisplayCommand(url: URL(string: "http://127.0.0.1:55777/display/set?name=Studio&brightness=0.6&token=secret")!)
        #expect(url == typed && http == typed)
        let toggle = try DisplayCommand(url: URL(string: "screenhelm://display/toggle?display=main&hdr")!)
        #expect(toggle == DisplayCommand(verb: .toggle, target: .main, names: ["hdr"]))
    }

    @Test func wrongCommandsSayWhatIsWrong() {
        func error(_ arguments: [String]) -> DisplayCommand.ParseError? {
            do { _ = try DisplayCommand(arguments: arguments); return nil } catch { return error }
        }
        #expect(error([]) == .noVerb)
        #expect(error(["destroy"]) == .unknownVerb("destroy"))
        #expect(error(["set", "sharpness=3"]) == .unknownSetting("sharpness"))
        #expect(error(["set", "brightness"]) == .wrongForm("brightness"))
        #expect(error(["set"]) == .nothingToDo)
        #expect(error(["toggle", "brightness"]) == .unknownSetting("brightness"))
        #expect(error(["toggle", "hdr=on"]) == .wrongForm("hdr"))
        #expect(error(["perform", "selfdestruct"]) == .unknownSetting("selfdestruct"))
        #expect(error(["perform"]) == .nothingToDo)
        #expect(error(["get"]) == nil)
        var failed = false
        do { _ = try DisplayCommand(url: URL(string: "screenhelm://other/set?brightness=1")!) } catch { failed = error == .noVerb }
        #expect(failed)
    }

    @Test func valuesAreRead() {
        #expect(DisplayCommand.fraction("0.6") == 0.6)
        #expect(DisplayCommand.fraction("60%") == 0.6)
        #expect(DisplayCommand.fraction("60") == 0.6)
        #expect(DisplayCommand.fraction("1.5") == 1.5) // XDR boost
        #expect(DisplayCommand.fraction("-1") == nil && DisplayCommand.fraction("900") == nil && DisplayCommand.fraction("bright") == nil)
        #expect(DisplayCommand.flag("on") == true && DisplayCommand.flag("No") == false && DisplayCommand.flag("maybe") == nil)
        #expect(DisplayCommand.size("1920x1080")?.width == 1920)
        #expect(DisplayCommand.size("2560×1440")?.height == 1440)
        #expect(DisplayCommand.size("big") == nil && DisplayCommand.size("0x0") == nil)
        #expect(DisplayCommand.vcp("0x10=50")?.code == 0x10)
        #expect(DisplayCommand.vcp("96=17")?.value == 17)
        #expect(DisplayCommand.vcp("0x1FF=1") == nil && DisplayCommand.vcp("16") == nil)
    }

    @Test func groupsSurviveStorage() {
        let groups = [DisplayGroup(name: "Desk", displays: ["a", "b"])]
        #expect(DisplayGroup.decode(DisplayGroup.encode(groups)) == groups)
        #expect(DisplayGroup.decode("x").isEmpty)
    }

    @Test func secretsAreComparedInFull() {
        #expect(ConstantTime.equal("s3cret-token", "s3cret-token"))
        #expect(!ConstantTime.equal("s3cret-token", "s3cret-tokeN"))
        #expect(!ConstantTime.equal("s3cret-token", "s3cret"))
        #expect(!ConstantTime.equal("", "x"))
        #expect(ConstantTime.equal("", ""))
    }
}
