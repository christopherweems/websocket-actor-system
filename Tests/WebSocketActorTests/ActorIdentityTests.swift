//
//  ActorIdentityTests.swift
//
//
//  Created by Stuart A. Malone on 11/2/23.
//

@testable import WebSocketActors
import Testing

struct ActorIdentityTests {
    @Test func testActorIdentitySyntax() throws {
        #expect(ActorIdentity(id: "foo") == ActorIdentity(id: "foo"))

        #expect(ActorIdentity.random() != ActorIdentity.random())

        #expect(ActorIdentity.random(for: Person.self).hasType(for: Person.self))
    }
}
