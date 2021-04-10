//
//  CameraViewController.swift
//
//  Created by Bryce Cogswell on 4/8/21.
//

import UIKit
import AVFoundation
import Vision

class CameraView: UIView, AVCapturePhotoCaptureDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {

	var captureSession: AVCaptureSession? = nil
	var stillImageOutput: AVCapturePhotoOutput? = nil
	var videoOutput: AVCaptureVideoDataOutput = AVCaptureVideoDataOutput()
	let videoOutputQueue = DispatchQueue(label: "com.gomaposm.openinghours.VideoOutputQueue")

	var captureCallback: ((CGImage)->(Void))? = nil

	override func layoutSubviews() {
		super.layoutSubviews()
		for layer in self.layer.sublayers ?? [] {
			layer.frame = CGRect(origin: layer.bounds.origin, size: self.layer.frame.size)
		}
	}

	override init(frame: CGRect) {

		super.init(frame: frame)

		// session
		let captureSession = AVCaptureSession()
		self.captureSession = captureSession
		captureSession.sessionPreset = AVCaptureSession.Preset.high

		// input source
		guard let backCamera = AVCaptureDevice.default(for: AVMediaType.video),
			  let input = try? AVCaptureDeviceInput(device: backCamera)
			  else { return }
		if captureSession.canAddInput(input) {
			captureSession.addInput(input)
		}

		// video output
		videoOutput.alwaysDiscardsLateVideoFrames = true
		videoOutput.setSampleBufferDelegate(self, queue: videoOutputQueue)
		if captureSession.canAddOutput(videoOutput) {
			captureSession.addOutput(videoOutput)
			videoOutput.connection(with: AVMediaType.video)?.preferredVideoStabilizationMode = .off
		}

		// photo output
		stillImageOutput =  AVCapturePhotoOutput()
		if captureSession.canAddOutput(stillImageOutput!) {
			captureSession.addOutput(stillImageOutput!)
		}

		// preview layer
		let previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
		previewLayer.videoGravity = AVLayerVideoGravity.resizeAspect
		previewLayer.connection?.videoOrientation = AVCaptureVideoOrientation.portrait
		self.layer.addSublayer(previewLayer)

		captureSession.startRunning()
	}

	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	func photoOutput(_ output: AVCapturePhotoOutput,
					 didFinishProcessingPhoto photo: AVCapturePhoto,
					 error: Error?)
	{
		let cgImage = photo.cgImageRepresentation()
		if let cgImage = cgImage?.takeUnretainedValue() {
			#if true
			self.captureCallback?( cgImage )
			#else
			let orientation = photo.metadata[kCGImagePropertyOrientation as String] as! NSNumber
			let uiOrientation = UIImage.Orientation(rawValue: orientation.intValue)!
			let image = UIImage(cgImage: cgImage, scale: 1, orientation: uiOrientation)
			self.captureCallback?( image )
			#endif
		}
	}

	@IBAction func takePhoto(sender: AnyObject?) {
		if let videoConnection = stillImageOutput!.connection(with: AVMediaType.video) {
			videoConnection.videoOrientation = AVCaptureVideoOrientation.portrait
			stillImageOutput?.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
		}
	}

	var boxLayers = [CALayer]()
	func captureOutput(_ output: AVCaptureOutput,
					   didOutput sampleBuffer: CMSampleBuffer,
					   from connection: AVCaptureConnection)
	{
		let orientation = CGImagePropertyOrientation.right
		let rotationTransform = CGAffineTransform(translationX: 0, y: 1).rotated(by: -CGFloat.pi / 2)
		let bottomToTopTransform = CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -1)
		let visionToAVFTransform = CGAffineTransform.identity.concatenating(bottomToTopTransform).concatenating(rotationTransform)

		if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
			let requestHandler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
													   orientation: orientation,
													   options: [:])
			let request = VNRecognizeTextRequest(completionHandler: {request, error in
				guard let results = request.results as? [VNRecognizedTextObservation] else { return }
				var boxes = [CGRect]()
				for result in results {
					guard let candidate = result.topCandidates(1).first else { continue }
					#if true
					let range = candidate.string.startIndex..<candidate.string.endIndex
					if let box = try? candidate.boundingBox(for: range)?.boundingBox {
						boxes.append( box )
					}
					#else
					let scanner = Scanner(string: candidate.string)
					while !scanner.isAtEnd {
						let start = scanner.currentIndex
						_ = scanner.scanUpToCharacters(from:CharacterSet.whitespacesAndNewlines)
						if let box = try? candidate.boundingBox(for: start..<scanner.currentIndex)?.boundingBox {
							boxes.append( box )
						}
						_ = scanner.scanCharacters(from:CharacterSet.whitespacesAndNewlines)
					}
					#endif
				}
				if boxes.count > 0 {
					DispatchQueue.main.async {
						if let previewLayer = self.layer.sublayers?.first as? AVCaptureVideoPreviewLayer {
							for layer in self.boxLayers {
								layer.removeFromSuperlayer()
							}
							self.boxLayers.removeAll()
							for box in boxes {
								let rect = previewLayer.layerRectConverted(fromMetadataOutputRect: box.applying(visionToAVFTransform))
								let layer = CAShapeLayer()
								layer.opacity = 1.0
								layer.borderColor = UIColor.green.cgColor
								layer.borderWidth = 2
								layer.frame = rect
								self.boxLayers.append(layer)
								previewLayer.insertSublayer(layer, at: 1)
							}
						}
					}
				}
			})
			request.recognitionLevel = .fast
			request.usesLanguageCorrection = false
			do {
				try requestHandler.perform([request])
			} catch {
				print(error)
			}
		}

	}
}