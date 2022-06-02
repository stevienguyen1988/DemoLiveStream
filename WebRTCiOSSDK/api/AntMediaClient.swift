//
//  WebRTCClient.swift
//  AntMediaSDK
//
//  Copyright © 2018 AntMedia. All rights reserved.
//

import Foundation
import AVFoundation
import Starscream
import WebRTC

let TAG: String = "AntMedia_iOS: "

public enum AntMediaClientMode: Int {
    case join = 1
    case play = 2
    case publish = 3
    case conference = 4;
    
    func getLeaveMessage() -> String {
        switch self {
            case .join:
                return "leave"
            case .publish, .play:
                return "stop"
            case .conference:
                return "leaveRoom"
        }
    }
    
    func getName() -> String {
        switch self {
            case .join:
                return "join"
            case .play:
                return "play"
            case .publish:
                return "publish"
            case .conference:
                return "conference"
        }
    }
    
}

open class AntMediaClient: NSObject, AntMediaClientProtocol {
    
    internal static var isDebug: Bool = false
    public var delegate: AntMediaClientDelegate!

    private var wsUrl: String!
    private var streamId: String!
    private var token: String!
    private var webSocket: WebSocket?
    private var mode: AntMediaClientMode!
    private var webRTCClient: WebRTCClient?
    private var localView: RTCVideoRenderer?
    private var remoteView: RTCVideoRenderer?
    
    private var videoContentMode: UIView.ContentMode?
    
    private let audioQueue = DispatchQueue(label: "audio")
    
    private let rtcAudioSession =  RTCAudioSession.sharedInstance()
    
    private var localContainerBounds: CGRect?
    private var remoteContainerBounds: CGRect?
    
    private var cameraPosition: AVCaptureDevice.Position = .front
    
    private var targetWidth: Int = 480
    private var targetHeight: Int = 360
    
    private var maxVideoBps: NSNumber = 0;
    
    private var videoEnable: Bool = true
    private var audioEnable: Bool = true
    
    private var multiPeer: Bool = false
        
    private var enableDataChannel: Bool = false
    
    private var multiPeerStreamId: String?
    
    //Screen capture of the app's screen.
    private var captureScreenEnabled: Bool = false
    
    private var isWebSocketConnected: Bool = false;
    
    private var externalAudioEnabled: Bool = false;
    
    // External video capture is getting frames from Broadcast Extension.
    //In order to make the broadcast extension to work both captureScreenEnable and
    // externalVideoCapture should be true
    private var externalVideoCapture: Bool = false;
    
    /*
     This peer mode is used in multi peer streaming
     */
    private var multiPeerMode: String = "play"
    
    var pingTimer: Timer?
    
    struct HandshakeMessage:Codable {
        var command:String?
        var streamId:String?
        var token:String?
        var video:Bool?
        var audio:Bool?
        var mode:String?
        var multiPeer:Bool?
    }
    
    public override init() {
        self.multiPeerStreamId = nil
     
     }
    
    public func setOptions(url: String, streamId: String, token: String = "", mode: AntMediaClientMode = .join, enableDataChannel: Bool = false, captureScreenEnabled: Bool = false) {
        self.wsUrl = url
        self.streamId = streamId
        self.token = token
        self.mode = mode
        self.rtcAudioSession.add(self)
        self.enableDataChannel = enableDataChannel
        self.captureScreenEnabled = captureScreenEnabled
    }
    
    public func setMaxVideoBps(videoBitratePerSecond: NSNumber) {
        self.maxVideoBps = videoBitratePerSecond;
        self.webRTCClient?.setMaxVideoBps(maxVideoBps: videoBitratePerSecond)
    }
    
    public func setMultiPeerMode(enable: Bool, mode: String) {
        self.multiPeer = enable
        self.multiPeerMode = mode;
    }
    
    public func setVideoEnable( enable: Bool) {
        self.videoEnable = enable
    }
    
    public func getStreamId() -> String {
        return self.streamId
    }
    
    func getHandshakeMessage() -> String {
        
        let handShakeMesage = HandshakeMessage(command: self.mode.getName(), streamId: self.streamId, token: self.token.isEmpty ? "" : self.token, video: self.videoEnable, audio:self.audioEnable, multiPeer: self.multiPeer && self.multiPeerStreamId != nil ? true : false)
        let json = try! JSONEncoder().encode(handShakeMesage)
        return String(data: json, encoding: .utf8)!
    }
    public func getLeaveMessage() -> [String: String] {
        return [COMMAND: self.mode.getLeaveMessage(), STREAM_ID: self.streamId]
    }
    
    // Force speaker
    public func speakerOn() {
       
        self.audioQueue.async { [weak self] in
            guard let self = self else {
                return
            }
            self.rtcAudioSession.lockForConfiguration()
            do {
                try self.rtcAudioSession.overrideOutputAudioPort(.speaker)
                try self.rtcAudioSession.setActive(true)
            } catch let error {
                AntMediaClient.printf("Couldn't force audio to speaker: \(error)")
            }
            self.rtcAudioSession.unlockForConfiguration()
        }
    }
    
    // Fallback to the default playing device: headphones/bluetooth/ear speaker
    public func speakerOff() {
        self.audioQueue.async { [weak self] in
            guard let self = self else {
                return
            }
            self.rtcAudioSession.lockForConfiguration()
            do {
                try self.rtcAudioSession.overrideOutputAudioPort(.none)
            } catch let error {
                debugPrint("Error setting AVAudioSession category: \(error)")
            }
            self.rtcAudioSession.unlockForConfiguration()
        }
    }

    
    open func start() {
        connectWebSocket()
    }
    
    /*
     Connect to websocket
     */
    open func connectWebSocket() {
        AntMediaClient.printf("Connect websocket to \(self.getWsUrl())")
        if (!self.isWebSocketConnected) { //provides backward compatibility
            AntMediaClient.printf("Will connect to: \(self.getWsUrl()) for stream: \(self.streamId)")
        
            webSocket = WebSocket(request: self.getRequest())
            webSocket?.delegate = self
            webSocket?.connect()
        }
        else {
            AntMediaClient.printf("WebSocket is already connected to: \(self.getWsUrl())")
        }
    }
    
    open func setCameraPosition(position: AVCaptureDevice.Position) {
        self.cameraPosition = position
    }
    
    open func setTargetResolution(width: Int, height: Int) {
        self.targetWidth = width
        self.targetHeight = height
    }
    
    /*
     Stops everything,
     Disconnects from websocket and
     stop webrtc
     */
    open func stop() {
        AntMediaClient.printf("Stop is called")
        if (self.isWebSocketConnected) {
            let jsonString = self.getLeaveMessage().json
            webSocket?.write(string: jsonString)
            self.webSocket?.disconnect()
        }
        self.webRTCClient?.disconnect()
        self.webRTCClient = nil
    }
    
    open func initPeerConnection() {
        
        if (self.webRTCClient == nil) {
            AntMediaClient.printf("Has wsClient? (start) : \(String(describing: self.webRTCClient))")
            self.webRTCClient = WebRTCClient.init(remoteVideoView: remoteView, localVideoView: localView, delegate: self, mode: self.mode, cameraPosition: self.cameraPosition, targetWidth: self.targetWidth, targetHeight: self.targetHeight, videoEnabled: self.videoEnable, multiPeerActive:  self.multiPeer, enableDataChannel: self.enableDataChannel, captureScreen: self.captureScreenEnabled, externalAudio: self.externalAudioEnabled)
            
            self.webRTCClient!.setStreamId(streamId)
            self.webRTCClient!.setToken(self.token)
        }
        else {
            AntMediaClient.printf("WebRTCClient already initialized")
        }
    }
    
    /*
     Just switches the camera. It works on the fly as well
     */
    open func switchCamera() {
        self.webRTCClient?.switchCamera()
    }

    /*
     Send data through WebRTC Data channel.
     */
    open func sendData(data: Data, binary: Bool = false) {
        self.webRTCClient?.sendData(data: data, binary: binary)
    }
    
    open func isDataChannelActive() -> Bool {
        return self.webRTCClient?.isDataChannelActive() ?? false
    }
        
    open func setLocalView( container: UIView, mode:UIView.ContentMode = .scaleAspectFit) {
       
        #if arch(arm64)
        let localRenderer = RTCMTLVideoView(frame: container.frame)
        localRenderer.videoContentMode =  mode
        #else
        let localRenderer = RTCEAGLVideoView(frame: container.frame)
        localRenderer.delegate = self
        #endif
 
        localRenderer.frame = container.bounds
        self.localView = localRenderer
        self.localContainerBounds = container.bounds
        
        self.embedView(localRenderer, into: container)
    }
    
    open func setRemoteView(remoteContainer: UIView, mode:UIView.ContentMode = .scaleAspectFit) {
       
        #if arch(arm64)
        let remoteRenderer = RTCMTLVideoView(frame: remoteContainer.frame)
        remoteRenderer.videoContentMode = mode
        #else
        let remoteRenderer = RTCEAGLVideoView(frame: remoteContainer.frame)
        remoteRenderer.delegate = self
        #endif
        
        remoteRenderer.frame = remoteContainer.frame
        
        self.remoteView = remoteRenderer
        self.remoteContainerBounds = remoteContainer.bounds
        self.embedView(remoteRenderer, into: remoteContainer)
        
    }
    
    private func embedView(_ view: UIView, into containerView: UIView) {
        containerView.addSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        containerView.addConstraints(NSLayoutConstraint.constraints(withVisualFormat: "H:|[view]|",
                                                                    options: [],
                                                                    metrics: nil,
                                                                    views: ["view":view]))
        
        containerView.addConstraints(NSLayoutConstraint.constraints(withVisualFormat: "V:|[view]|",
                                                                    options: [],
                                                                    metrics: nil,
                                                                    views: ["view":view]))
        containerView.layoutIfNeeded()
    }
    
    open func isConnected() -> Bool {
        return isWebSocketConnected;
    }
    
    open func setDebug(_ value: Bool) {
        AntMediaClient.isDebug = value
    }
    
    public static func setDebug(_ value: Bool) {
         AntMediaClient.isDebug = value
    }
    
    open func toggleAudio() {
        self.webRTCClient?.toggleAudioEnabled()
    }
    
    open func toggleVideo() {
        self.webRTCClient?.toggleVideoEnabled()
    }
    
    open func getCurrentMode() -> AntMediaClientMode {
        return self.mode
    }
    
    open func getWsUrl() -> String {
        return wsUrl;
    }
    
    private func onConnection() {
        if (isWebSocketConnected) {
            let jsonString = getHandshakeMessage()
            AntMediaClient.printf("onConnection message: \(jsonString)")
            webSocket!.write(string: jsonString)
        }
    }
    
    private func onJoined() {

    }
    
    
    private func onTakeConfiguration(message: [String: Any]) {
        var rtcSessionDesc: RTCSessionDescription
        let type = message["type"] as! String
        let sdp = message["sdp"] as! String
        
        if type == "offer" {
            rtcSessionDesc = RTCSessionDescription.init(type: RTCSdpType.offer, sdp: sdp)
            self.webRTCClient?.setRemoteDescription(rtcSessionDesc)
            self.webRTCClient?.sendAnswer()
        } else if type == "answer" {
            rtcSessionDesc = RTCSessionDescription.init(type: RTCSdpType.answer, sdp: sdp)
            self.webRTCClient?.setRemoteDescription(rtcSessionDesc)
        }
    }
    
    private func onTakeCandidate(message: [String: Any]) {
        let mid = message["id"] as! String
        let index = message["label"] as! Int
        let sdp = message["candidate"] as! String
        let candidate: RTCIceCandidate = RTCIceCandidate.init(sdp: sdp, sdpMLineIndex: Int32(index), sdpMid: mid)
        self.webRTCClient?.addCandidate(candidate)
    }
    
    private func onMessage(_ msg: String) {
        if let message = msg.toJSON() {
            guard let command = message[COMMAND] as? String else {
                return
            }
            self.onCommand(command, message: message)
        } else {
            print("WebSocket message JSON parsing error: " + msg)
        }
    }
    
    private func onCommand(_ command: String, message: [String: Any]) {
        
        switch command {
            case "start":
                //if this is called, it's publisher or initiator in p2p
                self.initPeerConnection()
                self.webRTCClient?.createOffer()
                break
            case "stop":
                self.webRTCClient?.stop()
                self.webRTCClient = nil
                self.delegate.remoteStreamRemoved(streamId: self.streamId)
                break
            case "takeConfiguration":
                self.initPeerConnection()
                self.onTakeConfiguration(message: message)
                break
            case "takeCandidate":
                self.onTakeCandidate(message: message)
                break
            case "connectWithNewId":
                self.multiPeerStreamId = message["streamId"] as? String
                let jsonString = getHandshakeMessage()
                webSocket!.write(string: jsonString)
                break
            case STREAM_INFORMATION_COMMAND:
                AntMediaClient.printf("stream information command")
                var streamInformations: [StreamInformation] = [];
                
                if let streamInformationArray = message["streamInfo"] as? [Any]
                {
                    for result in streamInformationArray
                    {
                        if let resultObject = result as? [String:Any]
                        {
                            streamInformations.append(StreamInformation(json: resultObject))
                        }
                    }
                }
                self.delegate.streamInformation(streamInfo: streamInformations);
                
                break
            case "notification":
                guard let definition = message["definition"] as? String else {
                    return
                }
                
                if definition == "joined" {
                    AntMediaClient.printf("Joined: Let's go")
                    self.onJoined()
                }
                else if definition == "play_started" {
                    AntMediaClient.printf("Play started: Let's go")
                    self.delegate.playStarted(streamId: self.streamId)
                }
                else if definition == "play_finished" {
                    AntMediaClient.printf("Playing has finished")
                    self.delegate.playFinished(streamId: self.streamId)
                }
                else if definition == "publish_started" {
                    AntMediaClient.printf("Publish started: Let's go")
                    self.webRTCClient?.setMaxVideoBps(maxVideoBps: self.maxVideoBps)
                    self.delegate.publishStarted(streamId: self.streamId)
                }
                else if definition == "publish_finished" {
                    AntMediaClient.printf("Play finished: Let's close")
                    self.delegate.publishFinished(streamId: self.streamId)
                }
                break
            case "error":
                guard let definition = message["definition"] as? String else {
                    self.delegate.clientHasError("An error occured, please try again")
                    return
                }
                
                self.delegate.clientHasError(AntMediaError.localized(definition))
                break
            default:
                break
        }
    }
    
    private func getRequest() -> URLRequest {
        var request = URLRequest(url: URL(string: self.getWsUrl())!)
        request.timeoutInterval = 5
        return request
    }
    
    public static func printf(_ msg: String) {
        if (AntMediaClient.isDebug) {
            debugPrint("--> AntMediaSDK: " + msg)
        }
    }
    
    public func getStreamInfo()
    {
        if (self.isWebSocketConnected)
        {
            self.webSocket?.write(string: [COMMAND: GET_STREAM_INFO_COMMAND, STREAM_ID: self.streamId].json)
        }
        else {
            AntMediaClient.printf("Websocket is not connected")
        }
    }
    
    public func forStreamQuality(resolutionHeight: Int)
    {
        if (self.isWebSocketConnected)
        {
            self.webSocket?.write(string: [COMMAND: FORCE_STREAM_QUALITY_INFO, STREAM_ID: self.streamId as String, STREAM_HEIGHT_FIELD: resolutionHeight].json)
        }
        else {
            AntMediaClient.printf("Websocket is not connected")
        }
    }
    
    public func getStats(completionHandler: @escaping (RTCStatisticsReport) -> Void) {
        self.webRTCClient?.getStats(handler: completionHandler)
    }
    
    public func deliverExternalAudio(sampleBuffer: CMSampleBuffer)
    {
        self.webRTCClient?.deliverExternalAudio(sampleBuffer: sampleBuffer);
    }
    
    
    public func setExternalAudio(externalAudioEnabled: Bool) {
        self.externalAudioEnabled = externalAudioEnabled;
    }
    
    public func setExternalVideoCapture(externalVideoCapture: Bool) {
        self.externalVideoCapture = externalVideoCapture;
    }
    
    public func deliverExternalVideo(sampleBuffer: CMSampleBuffer)
    {
        (self.webRTCClient?.getVideoCapturer() as? RTCCustomFrameCapturer)?.capture(sampleBuffer);
    }
    
}

extension AntMediaClient: WebRTCClientDelegate {

    public func sendMessage(_ message: [String : Any]) {
        self.webSocket?.write(string: message.json)
    }
    
    public func addLocalStream() {
        self.delegate.localStreamStarted(streamId: self.streamId)
    }
    
    public func addRemoteStream() {
        self.delegate.remoteStreamStarted(streamId: self.streamId)
    }
    
    public func connectionStateChanged(newState: RTCIceConnectionState) {
        if newState == RTCIceConnectionState.closed ||
            newState == RTCIceConnectionState.disconnected ||
            newState == RTCIceConnectionState.failed
        {
            AntMediaClient.printf("connectionStateChanged: \(newState.rawValue) for stream: \(String(describing: self.streamId))")
            self.delegate.disconnected(streamId: self.streamId);
        }
    }
    
    public func dataReceivedFromDataChannel(didReceiveData data: RTCDataBuffer) {
        self.delegate.dataReceivedFromDataChannel(streamId: streamId, data: data.data, binary: data.isBinary);
    }
    
}

extension AntMediaClient: WebSocketDelegate {
    
    
    public func getPingMessage() -> [String: String] {
           return [COMMAND: "ping"]
    }
    
    public func didReceive(event: WebSocketEvent, client: WebSocket) {
        switch event {
        case .connected(let headers):
            isWebSocketConnected = true;
            AntMediaClient.printf("websocket is connected: \(headers)")
            self.initPeerConnection()
            self.onConnection()
            self.delegate?.clientDidConnect(self)
            
            //too keep the connetion alive send ping command for every 10 seconds
            pingTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { pingTimer in
                let jsonString = self.getPingMessage().json
                self.webSocket?.write(string: jsonString)
            }
            break;
        case .disconnected(let reason, let code):
            isWebSocketConnected = false;
            AntMediaClient.printf("websocket is disconnected: \(reason) with code: \(code)")
            pingTimer?.invalidate()
        
            self.delegate?.clientDidDisconnect(String(code))
            break;
        case .text(let string):
            AntMediaClient.printf("Received text: \(string)");
            self.onMessage(string)
            break;
        case .binary(let data):
            AntMediaClient.printf("Received data: \(data.count)")
            break;
        case .ping(_):
            break
        case .pong(_):
            break
        case .viabilityChanged(_):
            break
        case .reconnectSuggested(_):
            break
        case .cancelled:
            isWebSocketConnected = false;
            pingTimer?.invalidate()
            break;
        case .error(let error):
            isWebSocketConnected = false;
            pingTimer?.invalidate()
            AntMediaClient.printf("Error occured on websocket connection \(String(describing: error))");
            break;
        default:
            AntMediaClient.printf("Unexpected command received from websocket");
            break;
        }
    }
}

extension AntMediaClient: RTCAudioSessionDelegate
{
    
    public func audioSessionDidStartPlayOrRecord(_ session: RTCAudioSession) {
        self.delegate.audioSessionDidStartPlayOrRecord(streamId: self.streamId)
    }

}

/*
 This delegate used non arm64 versions. In other words it's used for RTCEAGLVideoView
 */
extension AntMediaClient: RTCVideoViewDelegate {
    
    private func resizeVideoFrame(bounds: CGRect, size: CGSize, videoView: UIView) {
    
        let defaultAspectRatio: CGSize = CGSize(width: size.width, height: size.height)
    
        let videoFrame: CGRect = AVMakeRect(aspectRatio: defaultAspectRatio, insideRect: bounds)
    
        videoView.bounds = videoFrame
    
    }
    public func videoView(_ videoView: RTCVideoRenderer, didChangeVideoSize size: CGSize) {
        
        AntMediaClient.printf("Video size changed to " + String(Int(size.width)) + "x" + String(Int(size.height)))
        
        var bounds: CGRect?
        if videoView.isEqual(localView)
        {
            bounds = self.localContainerBounds ?? nil
        }
        else if videoView.isEqual(remoteView)
        {
            bounds = self.remoteContainerBounds ?? nil
        }
       
        if (bounds != nil)
        {
            resizeVideoFrame(bounds: bounds!, size: size, videoView: (videoView as? UIView)!)
        }
    }
}
