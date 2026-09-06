package com.hiddify.hiddify

import androidx.core.content.FileProvider

/** Свой подкласс, чтобы не конфликтовать с FileProvider-ами плагинов (share_plus, file_picker) при слиянии манифестов. */
class OknoFileProvider : FileProvider()
