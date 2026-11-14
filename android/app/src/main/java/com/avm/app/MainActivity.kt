package com.avm.app

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            AvmTheme {
                AvmScreen()
            }
        }
    }
}

@Composable
fun AvmTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit
) {
    val colorScheme = if (darkTheme) darkColorScheme() else lightColorScheme()
    MaterialTheme(
        colorScheme = colorScheme,
        content = content
    )
}

private fun stateLabelOf(state: Int): String = when (state) {
    AvmBridge.AVM_STATE_STOPPED -> "STOPPED / 已停止"
    AvmBridge.AVM_STATE_STARTING -> "STARTING / 启动中"
    AvmBridge.AVM_STATE_RUNNING -> "RUNNING / 运行中"
    AvmBridge.AVM_STATE_PAUSED -> "PAUSED / 已暂停"
    AvmBridge.AVM_STATE_STOPPING -> "STOPPING / 停止中"
    AvmBridge.AVM_STATE_ERROR -> "ERROR / 错误"
    else -> "UNKNOWN($state) / 未知"
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AvmScreen() {
    // ---- Form state ----
    var name by remember { mutableStateOf("vm0") }
    var qemuPath by remember { mutableStateOf("") }
    var machine by remember { mutableStateOf("virt") }
    var cpu by remember { mutableStateOf("host") }
    var smp by remember { mutableStateOf("1") }
    var memoryMb by remember { mutableStateOf("1024") }
    var accel by remember { mutableStateOf(AvmBridge.AVM_ACCEL_HOST) }
    var boot by remember { mutableStateOf(AvmBridge.AVM_BOOT_AUTO) }
    var kernel by remember { mutableStateOf("") }
    var initrd by remember { mutableStateOf("") }
    var cmdline by remember { mutableStateOf("") }
    var diskPath by remember { mutableStateOf("") }
    var cdrom by remember { mutableStateOf("") }
    var display by remember { mutableStateOf("none") }
    var extraArgs by remember { mutableStateOf("") }

    // ---- VM / UI state ----
    var handle by remember { mutableStateOf(0L) }
    var stateLabel by remember { mutableStateOf("STOPPED / 已停止") }
    var pid by remember { mutableStateOf(0) }
    val log = remember { mutableStateListOf<String>() }
    var showCommandDialog by remember { mutableStateOf(false) }
    var commandText by remember { mutableStateOf("") }

    fun log(msg: String) {
        log.add(msg)
    }

    fun refreshStatus() {
        stateLabel = stateLabelOf(AvmBridge.nativeState(handle))
        pid = AvmBridge.nativePid(handle)
        val running = AvmBridge.nativeIsRunning(handle)
        log("刷新: $stateLabel, running=$running, pid=$pid")
    }

    // Stable reference so onDispose always sees the current handle.
    val currentHandle = rememberUpdatedState(handle)
    DisposableEffect(Unit) {
        onDispose {
            val h = currentHandle.value
            if (h != 0L) {
                AvmBridge.nativeDestroy(h)
            }
        }
    }

    val hasVm = handle != 0L

    val accels = listOf(
        "HOST" to AvmBridge.AVM_ACCEL_HOST,
        "KVM" to AvmBridge.AVM_ACCEL_KVM,
        "HVF" to AvmBridge.AVM_ACCEL_HVF,
        "WHPX" to AvmBridge.AVM_ACCEL_WHPX,
        "TCG" to AvmBridge.AVM_ACCEL_TCG
    )
    val boots = listOf(
        "AUTO" to AvmBridge.AVM_BOOT_AUTO,
        "UEFI" to AvmBridge.AVM_BOOT_UEFI,
        "DIRECT_KERNEL" to AvmBridge.AVM_BOOT_DIRECT_KERNEL,
        "BIOS" to AvmBridge.AVM_BOOT_BIOS
    )

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(16.dp)
    ) {
        Text(
            text = "AVM 控制面板 · libavm ${AvmBridge.nativeVersion()}",
            style = MaterialTheme.typography.titleMedium
        )
        Spacer(Modifier.height(12.dp))

        // ---- qemuPath with auto-find ----
        Row(verticalAlignment = Alignment.CenterVertically) {
            OutlinedTextField(
                value = qemuPath,
                onValueChange = { qemuPath = it },
                label = { Text("QEMU 路径") },
                modifier = Modifier.weight(1f),
                singleLine = true
            )
            Spacer(Modifier.width(8.dp))
            Button(onClick = {
                try {
                    val found = AvmBridge.nativeFindQemu()
                    qemuPath = found
                    log("自动查找: $found")
                } catch (t: Throwable) {
                    log("自动查找失败: ${t.message}")
                }
            }) {
                Text("自动查找")
            }
        }
        Spacer(Modifier.height(8.dp))

        OutlinedTextField(value = name, onValueChange = { name = it }, label = { Text("名称") }, modifier = Modifier.fillMaxWidth(), singleLine = true)
        Spacer(Modifier.height(8.dp))
        OutlinedTextField(value = machine, onValueChange = { machine = it }, label = { Text("machine") }, modifier = Modifier.fillMaxWidth(), singleLine = true)
        Spacer(Modifier.height(8.dp))
        OutlinedTextField(value = cpu, onValueChange = { cpu = it }, label = { Text("cpu") }, modifier = Modifier.fillMaxWidth(), singleLine = true)
        Spacer(Modifier.height(8.dp))
        OutlinedTextField(value = smp, onValueChange = { smp = it }, label = { Text("smp") }, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number), modifier = Modifier.fillMaxWidth(), singleLine = true)
        Spacer(Modifier.height(8.dp))
        OutlinedTextField(value = memoryMb, onValueChange = { memoryMb = it }, label = { Text("内存 (MB)") }, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number), modifier = Modifier.fillMaxWidth(), singleLine = true)
        Spacer(Modifier.height(8.dp))
        OutlinedTextField(value = kernel, onValueChange = { kernel = it }, label = { Text("kernel") }, modifier = Modifier.fillMaxWidth(), singleLine = true)
        Spacer(Modifier.height(8.dp))
        OutlinedTextField(value = initrd, onValueChange = { initrd = it }, label = { Text("initrd") }, modifier = Modifier.fillMaxWidth(), singleLine = true)
        Spacer(Modifier.height(8.dp))
        OutlinedTextField(value = cmdline, onValueChange = { cmdline = it }, label = { Text("cmdline") }, modifier = Modifier.fillMaxWidth(), singleLine = true)
        Spacer(Modifier.height(8.dp))
        OutlinedTextField(value = diskPath, onValueChange = { diskPath = it }, label = { Text("磁盘路径") }, modifier = Modifier.fillMaxWidth(), singleLine = true)
        Spacer(Modifier.height(8.dp))
        OutlinedTextField(value = cdrom, onValueChange = { cdrom = it }, label = { Text("cdrom") }, modifier = Modifier.fillMaxWidth(), singleLine = true)
        Spacer(Modifier.height(8.dp))
        OutlinedTextField(value = display, onValueChange = { display = it }, label = { Text("display") }, modifier = Modifier.fillMaxWidth(), singleLine = true)
        Spacer(Modifier.height(8.dp))
        OutlinedTextField(value = extraArgs, onValueChange = { extraArgs = it }, label = { Text("额外参数") }, modifier = Modifier.fillMaxWidth(), singleLine = true)
        Spacer(Modifier.height(12.dp))

        // ---- accel chips ----
        Text("加速 (accel)", style = MaterialTheme.typography.labelLarge)
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            accels.forEach { (label, value) ->
                FilterChip(
                    selected = accel == value,
                    onClick = { accel = value },
                    label = { Text(label) }
                )
            }
        }
        Spacer(Modifier.height(12.dp))

        // ---- boot chips ----
        Text("启动方式 (boot)", style = MaterialTheme.typography.labelLarge)
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            boots.forEach { (label, value) ->
                FilterChip(
                    selected = boot == value,
                    onClick = { boot = value },
                    label = { Text(label) }
                )
            }
        }
        Spacer(Modifier.height(16.dp))

        // ---- action buttons ----
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Button(onClick = {
                val h = AvmBridge.nativeCreate(
                    name, qemuPath, machine, cpu,
                    smp.toIntOrNull() ?: 1,
                    memoryMb.toLongOrNull() ?: 1024L,
                    accel, boot, kernel, initrd, cmdline,
                    diskPath, cdrom, display, extraArgs
                )
                if (h != 0L) {
                    handle = h
                    log("VM 已创建 (handle=$h)")
                    refreshStatus()
                } else {
                    log("创建失败: ${AvmBridge.nativeStatusString(AvmBridge.AVM_ERR_INVALID_ARGUMENT)}")
                }
            }, enabled = !hasVm) {
                Text("创建VM")
            }
            Button(onClick = {
                val r = AvmBridge.nativeStart(handle)
                log("启动: ${AvmBridge.nativeStatusString(r)}")
                refreshStatus()
            }, enabled = hasVm) {
                Text("启动")
            }
            Button(onClick = {
                val r = AvmBridge.nativeStop(handle)
                log("停止: ${AvmBridge.nativeStatusString(r)}")
                refreshStatus()
            }, enabled = hasVm) {
                Text("停止")
            }
        }
        Spacer(Modifier.height(8.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Button(onClick = { refreshStatus() }, enabled = hasVm) {
                Text("刷新状态")
            }
            Button(onClick = {
                try {
                    val argv = AvmBridge.nativeBuildArgv(handle)
                    val desc = AvmBridge.nativeDescribe(handle)
                    commandText = "argv:\n$argv\n\n描述:\n$desc"
                    log("查看命令行")
                } catch (t: Throwable) {
                    commandText = "错误: ${t.message}"
                }
                showCommandDialog = true
            }, enabled = hasVm) {
                Text("查看命令行")
            }
        }
        Spacer(Modifier.height(16.dp))

        // ---- status card ----
        Card(modifier = Modifier.fillMaxWidth()) {
            Column(Modifier.padding(12.dp)) {
                Text("状态: $stateLabel", style = MaterialTheme.typography.bodyLarge)
                Text("PID: $pid", style = MaterialTheme.typography.bodyLarge)
                Spacer(Modifier.height(8.dp))
                Text("日志:", style = MaterialTheme.typography.labelLarge)
                log.takeLast(8).forEach { line ->
                    Text(line, style = MaterialTheme.typography.bodySmall)
                }
            }
        }
    }

    if (showCommandDialog) {
        AlertDialog(
            onDismissRequest = { showCommandDialog = false },
            title = { Text("命令行") },
            text = {
                Column(
                    modifier = Modifier
                        .heightIn(max = 400.dp)
                        .verticalScroll(rememberScrollState())
                ) {
                    Text(commandText)
                }
            },
            confirmButton = {
                TextButton(onClick = { showCommandDialog = false }) {
                    Text("关闭")
                }
            }
        )
    }
}
