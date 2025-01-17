//
//  MessageEndpointTest.swift
//  CouchbaseLite
//
//  Copyright (c) 2017 Couchbase, Inc All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

import XCTest
import MultipeerConnectivity
import CouchbaseLiteSwift

protocol MultipeerConnectionDelegate: class {
    
    func connectionDidOpen(_ connection: MessageEndpointConnection)
    
    func connectionDidClose(_ connection: MessageEndpointConnection)
    
}

class MultipeerConnection: MessageEndpointConnection {
    
    let session: MCSession
    
    let peerID: MCPeerID
    
    weak var delegate: MultipeerConnectionDelegate?
    
    var replConnection: ReplicatorConnection!
    
    init(session: MCSession, peerID: MCPeerID, delegate: MultipeerConnectionDelegate) {
        self.session = session
        self.peerID = peerID
        self.delegate = delegate
    }
    
    func receive(data: Data) {
        replConnection.receive(message: Message.fromData(data))
    }
    
    func open(connection: ReplicatorConnection, completion: @escaping (Bool, MessagingError?) -> Void) {
        replConnection = connection
        delegate?.connectionDidOpen(self)
        completion(true, nil)
    }
    
    func close(error: Error?, completion: @escaping () -> Void) {
        session.disconnect()
        delegate?.connectionDidClose(self)
        completion()
    }
    
    func send(message: Message, completion: @escaping (Bool, MessagingError?) -> Void) {
        do {
            try session.send(message.toData(), toPeers: [peerID], with: .reliable)
            completion(true, nil)
        }
        catch let error {
            completion(false, MessagingError(error: error, isRecoverable: false))
        }
    }
    
}

class MessageEndpointTest: CBLTestCase, MCNearbyServiceBrowserDelegate,
MCNearbyServiceAdvertiserDelegate, MCSessionDelegate, MessageEndpointDelegate,
MultipeerConnectionDelegate {
    
    var oDB: Database!
    
    var clientPeer: MCPeerID?
    var serverPeer: MCPeerID?

    var clientSession: MCSession?
    var serverSession: MCSession?

    var browser: MCNearbyServiceBrowser?
    var advertiser: MCNearbyServiceAdvertiser?
    
    var clientConnection: MultipeerConnection?
    var serverConnection: MultipeerConnection?
    
    var replicator: Replicator?
    var listener: MessageEndpointListener?

    var clientConnected: XCTestExpectation?
    var serverConnected: XCTestExpectation?
    
    override func setUp() {
        super.setUp()
        try! openOtherDB()
        oDB = otherDB!
    }
    
    override func tearDown() {
        listener?.closeAll()
        
        // Workaround to ensure that replicator's background cleaning task was done:
        // https://github.com/couchbase/couchbase-lite-core/issues/520
        Thread.sleep(forTimeInterval: 0.3);
        
        browser?.stopBrowsingForPeers()
        advertiser?.stopAdvertisingPeer()
        
        clientSession?.disconnect()
        serverSession?.disconnect()
        
        super.tearDown()
    }
    
    func startDiscovery() {
        serverConnected = self.allowOverfillExpectation(description: "Server Connected")
        serverPeer = MCPeerID(displayName: "server")
        serverSession = MCSession(peer: serverPeer!, securityIdentity: nil, encryptionPreference: .none)
        serverSession!.delegate = self
        advertiser = MCNearbyServiceAdvertiser(peer: serverPeer!, discoveryInfo: nil, serviceType: "MyService")
        advertiser!.delegate = self
        advertiser!.startAdvertisingPeer()
        
        clientConnected = self.allowOverfillExpectation(description: "Client Connected")
        clientPeer = MCPeerID(displayName: "client")
        clientSession = MCSession.init(peer: clientPeer!, securityIdentity: nil, encryptionPreference: .none)
        clientSession!.delegate = self
        browser = MCNearbyServiceBrowser.init(peer: clientPeer!, serviceType: "MyService")
        browser!.delegate = self
        browser!.startBrowsingForPeers()
        
        // cool down period(disconnected to next connected state), is taking around 4-10secs
        self.wait(for: [clientConnected!, serverConnected!], timeout: 30.0)
    }
    
    func run(config: ReplicatorConfiguration, collections: [Collection]? = nil, expectedError: Int? = nil) {
        // Start discovery:
        startDiscovery()
        
        // Start listener
        let x1 = self.expectation(description: "Listener Connecting")
        let x2 = self.expectation(description: "Listener Stopped")
        
        var listenerConfig: MessageEndpointListenerConfiguration!
        if let cols = collections {
            listenerConfig = MessageEndpointListenerConfiguration(collections: cols, protocolType: .messageStream)
        } else {
            listenerConfig = MessageEndpointListenerConfiguration(database: oDB, protocolType: .messageStream)
        }
        
        listener = MessageEndpointListener(config: listenerConfig)
        let token1 = listener!.addChangeListener({ (change) in
            let status = change.status
            if status.activity == .connecting {
                x1.fulfill()
            } else if status.activity == .stopped {
                x2.fulfill()
            }
        })
        listener!.accept(connection: MultipeerConnection(
            session: serverSession!, peerID: clientPeer!, delegate: self))
        self.wait(for: [x1], timeout: 10.0)
        
        let x3 = self.expectation(description: "Replicator Stopped")
        let repl = Replicator(config: config)
        let token2 = repl.addChangeListener { (change) in
            let status = change.status
            if config.continuous && status.activity == .idle &&
                status.progress.completed == status.progress.total {
                repl.stop()
            }
            
            if status.activity == .stopped {
                if let err = expectedError {
                    let error = status.error as NSError?
                    XCTAssertNotNil(error)
                    XCTAssertEqual(error!.code, err)
                }
                x3.fulfill()
            }
        }
        
        repl.start()
        wait(for: [x3], timeout: 10.0)
        repl.stop()
        repl.removeChangeListener(withToken: token2)
        
        listener!.closeAll()
        wait(for: [x2], timeout: 10.0)
        listener!.removeChangeListener(token: token1)
    }
    
    func run(config: ReplicatorConfiguration, expectedError: Int?) {
        run(config: config, expectedError: expectedError)
    }
    
    func config(target: Endpoint, type: ReplicatorType, continuous: Bool) -> ReplicatorConfiguration {
        var config = ReplicatorConfiguration(database: self.db, target: target)
        config.replicatorType = type
        config.continuous = continuous
        return config
    }
    
    // MARK: MCNearbyServiceBrowserDelegate
    
    func browser(_ browser: MCNearbyServiceBrowser,
                 foundPeer peerID: MCPeerID,
                 withDiscoveryInfo info: [String : String]?) {
        browser.invitePeer(peerID, to: clientSession!, withContext: nil, timeout: 0.0)
    }
    
    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) { }
    
    // MARK: MCNearbyServiceAdvertiserDelegate
    
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                    didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?,
                    invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        invitationHandler(true, serverSession)
    }
    
    // MARK: MCSessionDelegate
    
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        switch state {
            case .connecting:
                print("*** Connecting: \(peerID.displayName)")
            case .connected:
                print("*** Connected: \(peerID.displayName)")
                if session === serverSession {
                    serverConnected!.fulfill()
                } else {
                    clientConnected!.fulfill()
                }
            case .notConnected:
                print("*** Not Connected: \(peerID.displayName)")
            default:
                print("*** Unhandled State: \(state)")
        }
    }
    
    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        print("*** Received \(data.count) bytes from \(peerID.displayName) ")
        if session === serverSession {
            guard let serverConnection = serverConnection else {
                print("*** [ERR] server connection lost from \(peerID.displayName) ")
                return
            }
            
            serverConnection.receive(data: data)
            
        } else {
            guard let clientConnection = clientConnection else {
                print("*** [ERR] client connection lost from \(peerID.displayName) ")
                return
            }
            
            clientConnection.receive(data: data)
        }
    }
    
    func session(_ session: MCSession,
                 didReceive stream: InputStream,
                 withName streamName: String,
                 fromPeer peerID: MCPeerID) { /* Not supported */ }
    
    func session(_ session: MCSession,
                 didStartReceivingResourceWithName resourceName: String,
                 fromPeer peerID: MCPeerID,
                 with progress: Progress) { /* Not supported */ }
    
    func session(_ session: MCSession,
                 didFinishReceivingResourceWithName resourceName: String,
                 fromPeer peerID: MCPeerID,
                 at localURL: URL?,
                 withError error: Error?) { /* Not supported */ }
    
    // MARK: MultipeerConnectionDelegate
    
    func connectionDidOpen(_ connection: MessageEndpointConnection) {
        let conn = connection as! MultipeerConnection
        if conn.session === serverSession {
            serverConnection = conn
        } else {
            clientConnection = conn
        }
    }
    
    func connectionDidClose(_ connection: MessageEndpointConnection) {
        let conn = connection as! MultipeerConnection
        if conn.session === serverSession {
            serverConnection = nil
        } else {
            clientConnection = nil
        }
    }
    
    // MARK: MessageEndpointDelegate
    
    func createConnection(endpoint: MessageEndpoint) -> MessageEndpointConnection {
        return MultipeerConnection(session: clientSession!, peerID: serverPeer!, delegate: self)
    }
    
    // MARK: Tests
    
    // FIXME: https://issues.couchbase.com/browse/CBL-2959
    func _testPushDoc() throws {
        let doc1 = MutableDocument(id: "doc1")
        doc1.setString("Tiger", forKey: "name")
        try self.db.saveDocument(doc1)

        let doc2 = MutableDocument(id: "doc2")
        doc2.setString("Cat", forKey: "name")
        try self.oDB.saveDocument(doc2)
        
        let target = MessageEndpoint(uid: "UID:123", target: nil, protocolType: .messageStream, delegate: self)
        let config = self.config(target: target, type: .push, continuous: false)
        self.run(config: config, expectedError: nil)
        
        XCTAssertEqual(self.oDB.count, 2)
        let savedDoc = self.oDB.document(withID: "doc1")!
        XCTAssertEqual(savedDoc.string(forKey: "name"), "Tiger")
    }
    
    // FIXME: https://issues.couchbase.com/browse/CBL-2959
    func _testPullDoc() throws {
        let doc1 = MutableDocument(id: "doc1")
        doc1.setString("Tiger", forKey: "name")
        try self.db.saveDocument(doc1)
        
        let doc2 = MutableDocument(id: "doc2")
        doc2.setString("Cat", forKey: "name")
        try self.oDB.saveDocument(doc2)
        
        let target = MessageEndpoint(uid: "UID:123", target: nil, protocolType: .messageStream, delegate: self)
        let config = self.config(target: target, type: .pull, continuous: false)
        self.run(config: config, expectedError: nil)
        
        XCTAssertEqual(self.db.count, 2)
        let savedDoc = self.db.document(withID: "doc2")!
        XCTAssertEqual(savedDoc.string(forKey: "name"), "Cat")
    }
    
    // FIXME: https://issues.couchbase.com/browse/CBL-2959
    func _testPushPullDoc() throws {
        let doc1 = MutableDocument(id: "doc1")
        doc1.setString("Tiger", forKey: "name")
        try self.db.saveDocument(doc1)
        
        let doc2 = MutableDocument(id: "doc2")
        doc2.setString("Cat", forKey: "name")
        try self.oDB.saveDocument(doc2)
        
        let target = MessageEndpoint(uid: "UID:123", target: nil, protocolType: .messageStream, delegate: self)
        let config = self.config(target: target, type: .pushAndPull, continuous: false)
        self.run(config: config, expectedError: nil)
        
        XCTAssertEqual(self.oDB.count, 2)
        let savedDoc1 = self.oDB.document(withID: "doc1")!
        XCTAssertEqual(savedDoc1.string(forKey: "name"), "Tiger")
        
        XCTAssertEqual(self.db.count, 2)
        let savedDoc2 = self.db.document(withID: "doc2")!
        XCTAssertEqual(savedDoc2.string(forKey: "name"), "Cat")
    }
    
    // FIXME: https://issues.couchbase.com/browse/CBL-2959
    func _testPushDocContinous() throws {
        let doc1 = MutableDocument(id: "doc1")
        doc1.setString("Tiger", forKey: "name")
        try self.db.saveDocument(doc1)
        
        let doc2 = MutableDocument(id: "doc2")
        doc2.setString("Cat", forKey: "name")
        try self.oDB.saveDocument(doc2)
        
        let target = MessageEndpoint(uid: "UID:123", target: nil, protocolType: .messageStream, delegate: self)
        let config = self.config(target: target, type: .push, continuous: true)
        self.run(config: config, expectedError: nil)
        
        XCTAssertEqual(self.oDB.count, 2)
        let savedDoc = self.oDB.document(withID: "doc1")!
        XCTAssertEqual(savedDoc.string(forKey: "name"), "Tiger")
    }
    
    // FIXME: https://issues.couchbase.com/browse/CBL-2959
    func _testPullDocContinous() throws {
        let doc1 = MutableDocument(id: "doc1")
        doc1.setString("Tiger", forKey: "name")
        try self.db.saveDocument(doc1)
        
        let doc2 = MutableDocument(id: "doc2")
        doc2.setString("Cat", forKey: "name")
        try self.oDB.saveDocument(doc2)
        
        let target = MessageEndpoint(uid: "UID:123", target: nil, protocolType: .messageStream, delegate: self)
        let config = self.config(target: target, type: .pull, continuous: true)
        self.run(config: config, expectedError: nil)
        
        XCTAssertEqual(self.db.count, 2)
        let savedDoc = self.db.document(withID: "doc2")!
        XCTAssertEqual(savedDoc.string(forKey: "name"), "Cat")
    }
    
    // FIXME: https://issues.couchbase.com/browse/CBL-2959
    func _testPushPullDocContinous() throws {
        let doc1 = MutableDocument(id: "doc1")
        doc1.setString("Tiger", forKey: "name")
        try self.db.saveDocument(doc1)
        
        let doc2 = MutableDocument(id: "doc2")
        doc2.setString("Cat", forKey: "name")
        try self.oDB.saveDocument(doc2)
        
        let target = MessageEndpoint(uid: "UID:123", target: nil, protocolType: .messageStream, delegate: self)
        let config = self.config(target: target, type: .pushAndPull, continuous: true)
        self.run(config: config, expectedError: nil)
        
        XCTAssertEqual(self.oDB.count, 2)
        let savedDoc1 = self.oDB.document(withID: "doc1")!
        XCTAssertEqual(savedDoc1.string(forKey: "name"), "Tiger")
        
        XCTAssertEqual(self.db.count, 2)
        let savedDoc2 = self.db.document(withID: "doc2")!
        XCTAssertEqual(savedDoc2.string(forKey: "name"), "Cat")
    }
    
    // MARK: 8.16 MessageEndpointListener tests
    
    func testCollectionsSingleShotPushPullReplication() throws {
        try testCollectionsPushPullReplication(continuous: false)
    }
    
    func testCollectionsContinuousPushPullReplication() throws {
        try testCollectionsPushPullReplication(continuous: true)
    }
    
    func testCollectionsPushPullReplication(continuous: Bool) throws {
        let col1a = try self.db.createCollection(name: "colA", scope: "scopeA")
        let col1b = try self.db.createCollection(name: "colB", scope: "scopeA")
        
        let col2a = try oDB.createCollection(name: "colA", scope: "scopeA")
        let col2b = try oDB.createCollection(name: "colB", scope: "scopeA")
        
        try createDocNumbered(col1a, start: 0, num: 1)
        try createDocNumbered(col1b, start: 5, num: 2)
        try createDocNumbered(col2a, start: 10, num: 3)
        try createDocNumbered(col2b, start: 15, num: 5)
        XCTAssertEqual(col1a.count, 1)
        XCTAssertEqual(col1b.count, 2)
        XCTAssertEqual(col2a.count, 3)
        XCTAssertEqual(col2b.count, 5)
        
        let target = MessageEndpoint(uid: "UID:123", target: nil, protocolType: .messageStream, delegate: self)
        var config = ReplicatorConfiguration(target: target)
        config.continuous = continuous
        config.addCollections([col1a, col1b])
        
        run(config: config, collections: [col2a, col2b])
        XCTAssertEqual(col1a.count, 4)
        XCTAssertEqual(col1b.count, 7)
        XCTAssertEqual(col2a.count, 4)
        XCTAssertEqual(col2b.count, 7)
    }
    
    func testMismatchedCollectionReplication() throws {
        let col1a = try self.db.createCollection(name: "colA", scope: "scopeA")
        let col2b = try oDB.createCollection(name: "colB", scope: "scopeA")
        
        let target = MessageEndpoint(uid: "UID:123", target: nil, protocolType: .messageStream, delegate: self)
        var config = ReplicatorConfiguration(target: target)
        config.addCollections([col1a])
        
        run(config: config, collections: [col2b], expectedError: CBLErrorHTTPNotFound)
    }
    
    // Note: fatalError with this test
    func _testCreateListenerConfigWithEmptyCollection() throws {
        expectExcepion(exception: .invalidArgumentException) {
            let _ = MessageEndpointListenerConfiguration(collections: [], protocolType: .messageStream)
        }
    }
    
}
