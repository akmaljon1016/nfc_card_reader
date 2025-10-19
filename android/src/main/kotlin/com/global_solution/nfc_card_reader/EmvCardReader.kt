package com.global_solution.nfc_card_reader

import android.nfc.tech.IsoDep
import android.util.Log

class EmvCardReader(private val isoDep: IsoDep) {

    private val TAG = "EmvCardReader"

    private val AIDS = listOf(
        byteArrayOf(0xA0.toByte(), 0x00, 0x00, 0x00, 0x03, 0x10, 0x10), // Visa
        byteArrayOf(0xA0.toByte(), 0x00, 0x00, 0x00, 0x04, 0x10, 0x10), // Mastercard
        byteArrayOf(0xA0.toByte(), 0x00, 0x00, 0x00, 0x03, 0x20, 0x10), // Visa Debit
        byteArrayOf(0xA0.toByte(), 0x00, 0x00, 0x00, 0x03, 0x20, 0x20), // Visa Electron
        byteArrayOf(0xA0.toByte(), 0x00, 0x00, 0x00, 0x04, 0x30, 0x60), // Maestro
        byteArrayOf(0xA0.toByte(), 0x00, 0x00, 0x00, 0x25, 0x01), // Amex
        byteArrayOf(0xA0.toByte(), 0x00, 0x00, 0x01, 0x52, 0x30, 0x10), // Discover
        byteArrayOf(0xA0.toByte(), 0x00, 0x00, 0x03, 0x33, 0x01, 0x01)  // UnionPay
    )

    fun readCardData(): CardData? {
        Log.d(TAG, "Starting card read")

        // Try PPSE first
        try {
            Log.d(TAG, "Trying PPSE")
            val ppseResponse = selectPPSE()
            if (isSuccessResponse(ppseResponse)) {
                Log.d(TAG, "PPSE selected successfully")
                val aid = extractAIDFromPPSE(ppseResponse)
                aid?.let {
                    Log.d(TAG, "Found AID from PPSE: ${toHex(it)}")
                    val cardData = tryReadWithAID(it)
                    if (cardData != null) return cardData
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "PPSE failed", e)
        }

        // Try each known AID
        for (aid in AIDS) {
            try {
                Log.d(TAG, "Trying AID: ${toHex(aid)}")
                val cardData = tryReadWithAID(aid)
                if (cardData != null) return cardData
            } catch (e: Exception) {
                Log.e(TAG, "AID ${toHex(aid)} failed", e)
                continue
            }
        }

        return null
    }

    private fun selectPPSE(): ByteArray {
        val ppseName = "2PAY.SYS.DDF01"
        return selectByName(ppseName.toByteArray())
    }

    private fun selectByName(name: ByteArray): ByteArray {
        val command = ByteArray(6 + name.size)
        command[0] = 0x00
        command[1] = 0xA4.toByte()
        command[2] = 0x04
        command[3] = 0x00
        command[4] = name.size.toByte()
        System.arraycopy(name, 0, command, 5, name.size)
        command[5 + name.size] = 0x00
        return isoDep.transceive(command)
    }

    private fun extractAIDFromPPSE(response: ByteArray): ByteArray? {
        val tlvData = parseTLV(response)
        for ((tag, value) in tlvData) {
            if (tag.contentEquals(byteArrayOf(0x4F))) {
                return value
            }
        }
        return null
    }

    private fun tryReadWithAID(aid: ByteArray): CardData? {
        val selectResponse = selectApplication(aid)
        if (!isSuccessResponse(selectResponse)) {
            Log.d(TAG, "SELECT failed for AID ${toHex(aid)}")
            return null
        }

        Log.d(TAG, "SELECT successful: ${toHex(selectResponse)}")

        // Try extracting data from SELECT response first
        val dataFromSelect = extractCardData(selectResponse)
        if (dataFromSelect != null) {
            Log.d(TAG, "Found card data in SELECT response")
            return dataFromSelect
        }

        // Try GPO
        try {
            val pdol = extractPDOL(selectResponse)
            val gpoResponse = sendGPO(pdol)

            if (isSuccessResponse(gpoResponse)) {
                Log.d(TAG, "GPO successful: ${toHex(gpoResponse)}")

                val dataFromGPO = extractCardData(gpoResponse)
                if (dataFromGPO != null) {
                    Log.d(TAG, "Found card data in GPO response")
                    return dataFromGPO
                }

                val aflList = extractAFL(gpoResponse)
                for (afl in aflList) {
                    try {
                        val recordResponse = readRecord(afl.sfi, afl.record)
                        if (isSuccessResponse(recordResponse)) {
                            Log.d(TAG, "READ RECORD successful: ${toHex(recordResponse)}")
                            val cardData = extractCardData(recordResponse)
                            if (cardData != null) return cardData
                        }
                    } catch (e: Exception) {
                        Log.e(TAG, "READ RECORD failed", e)
                        continue
                    }
                }
            } else {
                Log.d(TAG, "GPO failed: ${toHex(gpoResponse)}")
            }
        } catch (e: Exception) {
            Log.e(TAG, "GPO/READ RECORD sequence failed", e)
        }

        return null
    }

    private fun selectApplication(aid: ByteArray): ByteArray {
        val command = ByteArray(6 + aid.size)
        command[0] = 0x00
        command[1] = 0xA4.toByte()
        command[2] = 0x04
        command[3] = 0x00
        command[4] = aid.size.toByte()
        System.arraycopy(aid, 0, command, 5, aid.size)
        command[5 + aid.size] = 0x00
        return isoDep.transceive(command)
    }

    private fun extractPDOL(response: ByteArray): ByteArray? {
        val tlvData = parseTLV(response)
        for ((tag, value) in tlvData) {
            if (tag.size == 2 && tag[0] == 0x9F.toByte() && tag[1] == 0x38.toByte()) {
                return value
            }
        }
        return null
    }

    private fun sendGPO(pdol: ByteArray?): ByteArray {
        val pdolData = if (pdol != null && pdol.isNotEmpty()) {
            ByteArray(getTotalPDOLLength(pdol))
        } else {
            byteArrayOf()
        }

        val commandData = ByteArray(2 + pdolData.size)
        commandData[0] = 0x83.toByte()
        commandData[1] = pdolData.size.toByte()
        System.arraycopy(pdolData, 0, commandData, 2, pdolData.size)

        val command = ByteArray(6 + commandData.size)
        command[0] = 0x80.toByte()
        command[1] = 0xA8.toByte()
        command[2] = 0x00
        command[3] = 0x00
        command[4] = commandData.size.toByte()
        System.arraycopy(commandData, 0, command, 5, commandData.size)
        command[5 + commandData.size] = 0x00

        return isoDep.transceive(command)
    }

    private fun getTotalPDOLLength(pdol: ByteArray): Int {
        var totalLength = 0
        var i = 0
        while (i < pdol.size) {
            if ((pdol[i].toInt() and 0x1F) == 0x1F && i + 1 < pdol.size) {
                i += 2
            } else {
                i++
            }
            if (i < pdol.size) {
                totalLength += pdol[i].toInt() and 0xFF
                i++
            }
        }
        return totalLength
    }

    private fun extractAFL(gpoResponse: ByteArray): List<AFLRecord> {
        val records = mutableListOf<AFLRecord>()
        val tlvData = parseTLV(gpoResponse)

        for ((tag, value) in tlvData) {
            if (tag.contentEquals(byteArrayOf(0x94.toByte()))) {
                var i = 0
                while (i + 3 < value.size) {
                    val sfi = (value[i].toInt() and 0xFF) shr 3
                    val firstRecord = value[i + 1].toInt() and 0xFF
                    val lastRecord = value[i + 2].toInt() and 0xFF

                    for (record in firstRecord..lastRecord) {
                        records.add(AFLRecord(sfi, record))
                    }
                    i += 4
                }
            } else if (tag.contentEquals(byteArrayOf(0x80.toByte()))) {
                if (value.size >= 4) {
                    for (sfi in 1..3) {
                        for (rec in 1..5) {
                            records.add(AFLRecord(sfi, rec))
                        }
                    }
                }
            }
        }

        if (records.isEmpty()) {
            for (sfi in 1..3) {
                for (rec in 1..5) {
                    records.add(AFLRecord(sfi, rec))
                }
            }
        }

        return records
    }

    private fun readRecord(sfi: Int, recordNumber: Int): ByteArray {
        val command = ByteArray(5)
        command[0] = 0x00
        command[1] = 0xB2.toByte()
        command[2] = recordNumber.toByte()
        command[3] = ((sfi shl 3) or 0x04).toByte()
        command[4] = 0x00
        return isoDep.transceive(command)
    }

    private fun extractCardData(response: ByteArray): CardData? {
        var cardNumber: String? = null
        var expirationDate: String? = null
        var cardholderName: String? = null

        val tlvData = parseTLV(response)
        Log.d(TAG, "Extracting card data from ${tlvData.size} TLV tags")

        for ((tag, value) in tlvData) {
            val tagHex = toHex(tag)
            when {
                tag.contentEquals(byteArrayOf(0x57)) -> {
                    Log.d(TAG, "Found Track 2 (0x57): ${toHex(value)}")
                    val track2 = parseTrack2Data(value)
                    if (cardNumber == null) cardNumber = track2?.first
                    if (expirationDate == null) expirationDate = track2?.second
                    Log.d(TAG, "Parsed Track 2 - PAN: $cardNumber, Exp: $expirationDate")
                }
                tag.contentEquals(byteArrayOf(0x5A)) -> {
                    Log.d(TAG, "Found PAN (0x5A): ${toHex(value)}")
                    if (cardNumber == null) cardNumber = parsePan(value)
                    Log.d(TAG, "Parsed PAN: $cardNumber")
                }
                tag.contentEquals(byteArrayOf(0x5F, 0x24)) -> {
                    Log.d(TAG, "Found Expiration Date (0x5F24): ${toHex(value)}")
                    if (expirationDate == null) expirationDate = parseExpirationDate(value)
                    Log.d(TAG, "Parsed Expiration: $expirationDate")
                }
                tag.contentEquals(byteArrayOf(0x5F, 0x20)) -> {
                    Log.d(TAG, "Found Cardholder Name (0x5F20): ${toHex(value)}")
                    if (cardholderName == null) {
                        cardholderName = String(value).trim().replace("/", " ")
                    }
                    Log.d(TAG, "Parsed Name: $cardholderName")
                }
            }
        }

        Log.d(TAG, "Final extraction result - PAN: $cardNumber, Exp: $expirationDate, Name: $cardholderName")
        return if (cardNumber != null && expirationDate != null) {
            CardData(cardNumber, expirationDate, cardholderName)
        } else {
            Log.d(TAG, "Card data incomplete, returning null")
            null
        }
    }

    private fun parseTLV(data: ByteArray): List<Pair<ByteArray, ByteArray>> {
        val result = mutableListOf<Pair<ByteArray, ByteArray>>()
        var i = 0

        while (i < data.size - 2) {
            val tag: ByteArray

            if ((data[i].toInt() and 0x1F) == 0x1F) {
                if (i + 1 >= data.size) break
                tag = byteArrayOf(data[i], data[i + 1])
                i += 2
            } else {
                tag = byteArrayOf(data[i])
                i++
            }

            if (i >= data.size) break

            var length = data[i].toInt() and 0xFF
            i++

            if (length > 127) {
                val numLengthBytes = length and 0x7F
                if (i + numLengthBytes > data.size) break

                length = 0
                for (j in 0 until numLengthBytes) {
                    length = (length shl 8) or (data[i].toInt() and 0xFF)
                    i++
                }
            }

            if (i + length > data.size) break

            val value = data.copyOfRange(i, i + length)
            result.add(Pair(tag, value))

            if ((tag[0].toInt() and 0x20) != 0) {
                result.addAll(parseTLV(value))
            }

            i += length
        }

        return result
    }

    private fun parseTrack2Data(data: ByteArray): Pair<String, String>? {
        val track2Hex = toHex(data)
        val separatorIndex = track2Hex.indexOfAny(charArrayOf('D', '='))

        if (separatorIndex > 0 && separatorIndex + 4 <= track2Hex.length) {
            val pan = track2Hex.substring(0, separatorIndex)
            val expDate = track2Hex.substring(separatorIndex + 1, separatorIndex + 5)

            return Pair(
                formatCardNumber(pan.replace("F", "")),
                formatExpirationDate(expDate)
            )
        }
        return null
    }

    private fun parsePan(data: ByteArray): String {
        val pan = toHex(data)
        return formatCardNumber(pan.replace("F", ""))
    }

    private fun parseExpirationDate(data: ByteArray): String {
        val date = toHex(data)
        return formatExpirationDate(date)
    }

    private fun formatCardNumber(pan: String): String {
        return pan.chunked(4).joinToString(" ")
    }

    private fun formatExpirationDate(date: String): String {
        if (date.length >= 4) {
            val year = date.substring(0, 2)
            val month = date.substring(2, 4)
            return "$month/$year"
        }
        return date
    }

    private fun isSuccessResponse(response: ByteArray): Boolean {
        return response.size >= 2 &&
                response[response.size - 2] == 0x90.toByte() &&
                response[response.size - 1] == 0x00.toByte()
    }

    private fun toHex(bytes: ByteArray): String {
        return bytes.joinToString("") { "%02X".format(it) }
    }

    data class AFLRecord(val sfi: Int, val record: Int)
}