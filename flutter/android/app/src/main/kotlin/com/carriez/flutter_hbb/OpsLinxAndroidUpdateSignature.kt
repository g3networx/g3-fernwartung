package com.carriez.flutter_hbb

import java.io.File
import java.security.MessageDigest
import java.util.Date
import org.bouncycastle.asn1.nist.NISTObjectIdentifiers
import org.bouncycastle.cms.CMSProcessableFile
import org.bouncycastle.cms.CMSSignedData
import org.bouncycastle.cms.jcajce.JcaSimpleSignerInfoVerifierBuilder
import org.bouncycastle.jce.provider.BouncyCastleProvider
import org.bouncycastle.util.encoders.Hex

internal object OpsLinxAndroidUpdateSignature {
    private const val MAX_PROOF_SIZE = 64 * 1024
    private val certumCertificate = Hex.decode(
        "8182b64c243398abc093b5359743dfcc6cbbae9b397d9e109def321c2ae9e0ee"
    )

    fun verify(apk: File, proof: ByteArray) {
        require(proof.size in 1..MAX_PROOF_SIZE)
        val signed = CMSSignedData(CMSProcessableFile(apk), proof)
        require(signed.isDetachedSignature)
        val signer = signed.signerInfos.signers.single()
        require(signer.digestAlgOID == NISTObjectIdentifiers.id_sha256.id)
        val certificate = signed.certificates.getMatches(null).single { signer.sid.match(it) }
        val fingerprint = MessageDigest.getInstance("SHA-256").digest(certificate.encoded)
        require(MessageDigest.isEqual(fingerprint, certumCertificate) && certificate.isValidOn(Date()))
        // Android's system BC provider is a different implementation.
        val verifier = JcaSimpleSignerInfoVerifierBuilder()
            .setProvider(BouncyCastleProvider())
            .build(certificate)
        require(signer.verify(verifier))
    }
}
