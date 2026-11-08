import SwiftUI

struct RegisterDefinition: Identifiable {
    let id = UUID()
    let peripheral: String
    let name: String
    let address: String
    let purpose: String
    let access: String
    let generic: Bool
    var available: Bool = true
}

enum RegisterCatalog {
    static func registers(family: String, model: String = "") -> [RegisterDefinition] {
        let source = family.hasPrefix("STM32G") ? g4 : f1
        return source.map { item in
            var copy = item
            copy.available = isAvailable(item.name, family: family, model: model)
            return copy
        }
    }

    private static let f1 = f1GPIO + [
        RegisterDefinition(peripheral:"USART",name:"USART1_SR",address:"0x40013800",purpose:"状态寄存器",access:"只读",generic:true),
        RegisterDefinition(peripheral:"USART",name:"USART1_DR",address:"0x40013804",purpose:"数据寄存器",access:"读写",generic:true),
        RegisterDefinition(peripheral:"USART",name:"USART1_BRR",address:"0x40013808",purpose:"波特率",access:"读写",generic:true),
        RegisterDefinition(peripheral:"USART",name:"USART1_CR1",address:"0x4001380C",purpose:"控制寄存器 1",access:"读写",generic:true),
        RegisterDefinition(peripheral:"SPI",name:"SPI1_SR",address:"0x40013008",purpose:"状态寄存器",access:"只读",generic:true),
        RegisterDefinition(peripheral:"SPI",name:"SPI1_DR",address:"0x4001300C",purpose:"数据寄存器",access:"读写",generic:true),
        RegisterDefinition(peripheral:"I2C",name:"I2C1_SR1",address:"0x40005414",purpose:"状态寄存器 1",access:"只读",generic:true),
        RegisterDefinition(peripheral:"I2C",name:"I2C1_DR",address:"0x40005410",purpose:"数据寄存器",access:"读写",generic:true),
        RegisterDefinition(peripheral:"DMA",name:"DMA1_CCR1",address:"0x40020008",purpose:"通道配置",access:"读写",generic:true),
        RegisterDefinition(peripheral:"DMA",name:"DMA1_CNDTR1",address:"0x4002000C",purpose:"剩余传输数量",access:"读写",generic:true),
        RegisterDefinition(peripheral:"DMA",name:"DMA1_CPAR1",address:"0x40020010",purpose:"外设地址",access:"读写",generic:true),
        RegisterDefinition(peripheral:"DMA",name:"DMA1_CMAR1",address:"0x40020014",purpose:"存储器地址",access:"读写",generic:true),
        RegisterDefinition(peripheral:"TIM",name:"TIM2_CR1",address:"0x40000000",purpose:"控制寄存器 1",access:"读写",generic:true),
        RegisterDefinition(peripheral:"TIM",name:"TIM2_SR",address:"0x40000010",purpose:"状态寄存器",access:"读写",generic:true),
        RegisterDefinition(peripheral:"TIM",name:"TIM2_CNT",address:"0x40000024",purpose:"计数器",access:"读写",generic:true),
        RegisterDefinition(peripheral:"TIM",name:"TIM2_PSC",address:"0x40000028",purpose:"预分频",access:"读写",generic:true),
        RegisterDefinition(peripheral:"TIM",name:"TIM2_ARR",address:"0x4000002C",purpose:"自动重装载",access:"读写",generic:true),
        RegisterDefinition(peripheral:"ADC",name:"ADC1_SR",address:"0x40012400",purpose:"状态寄存器",access:"读写",generic:true),
        RegisterDefinition(peripheral:"ADC",name:"ADC1_CR2",address:"0x40012408",purpose:"控制寄存器 2",access:"读写",generic:true),
        RegisterDefinition(peripheral:"ADC",name:"ADC1_DR",address:"0x4001244C",purpose:"转换数据",access:"只读",generic:true),
        RegisterDefinition(peripheral:"RCC",name:"RCC_APB2ENR",address:"0x40021018",purpose:"APB2 外设时钟使能",access:"读写",generic:true),
        RegisterDefinition(peripheral:"RCC",name:"RCC_APB1ENR",address:"0x4002101C",purpose:"APB1 外设时钟使能",access:"读写",generic:true),
        RegisterDefinition(peripheral:"EXTI",name:"EXTI_IMR",address:"0x40010400",purpose:"中断屏蔽",access:"读写",generic:true),
        RegisterDefinition(peripheral:"EXTI",name:"EXTI_PR",address:"0x40010414",purpose:"挂起标志",access:"读写",generic:true),
        RegisterDefinition(peripheral:"NVIC",name:"NVIC_ISER0",address:"0xE000E100",purpose:"中断使能",access:"读写",generic:true),
        RegisterDefinition(peripheral:"NVIC",name:"SCB_ICSR",address:"0xE000ED04",purpose:"系统控制状态",access:"读写",generic:true)
    ] + f1Extra + f1Instances

    private static let g4 = g4GPIO + [
        RegisterDefinition(peripheral:"USART",name:"USART1_ISR",address:"0x4001381C",purpose:"中断与状态",access:"只读",generic:true),
        RegisterDefinition(peripheral:"USART",name:"USART1_RDR",address:"0x40013824",purpose:"接收数据",access:"只读",generic:true),
        RegisterDefinition(peripheral:"USART",name:"USART1_TDR",address:"0x40013828",purpose:"发送数据",access:"只写",generic:true),
        RegisterDefinition(peripheral:"USART",name:"USART1_BRR",address:"0x4001380C",purpose:"波特率",access:"读写",generic:true),
        RegisterDefinition(peripheral:"SPI",name:"SPI1_SR",address:"0x40013008",purpose:"状态寄存器",access:"只读",generic:true),
        RegisterDefinition(peripheral:"SPI",name:"SPI1_TXDR",address:"0x40013020",purpose:"发送数据",access:"读写",generic:true),
        RegisterDefinition(peripheral:"I2C",name:"I2C1_ISR",address:"0x40005418",purpose:"状态寄存器",access:"只读",generic:true),
        RegisterDefinition(peripheral:"I2C",name:"I2C1_TXDR",address:"0x40005428",purpose:"发送数据",access:"读写",generic:true),
        RegisterDefinition(peripheral:"DMA",name:"DMA1_CCR1",address:"0x40020008",purpose:"通道配置",access:"读写",generic:true),
        RegisterDefinition(peripheral:"DMA",name:"DMA1_CNDTR1",address:"0x4002000C",purpose:"剩余传输数量",access:"读写",generic:true),
        RegisterDefinition(peripheral:"DMA",name:"DMA1_CPAR1",address:"0x40020010",purpose:"外设地址",access:"读写",generic:true),
        RegisterDefinition(peripheral:"DMA",name:"DMA1_CMAR1",address:"0x40020014",purpose:"存储器地址",access:"读写",generic:true),
        RegisterDefinition(peripheral:"TIM",name:"TIM2_CR1",address:"0x40000000",purpose:"控制寄存器 1",access:"读写",generic:true),
        RegisterDefinition(peripheral:"TIM",name:"TIM2_SR",address:"0x40000010",purpose:"状态寄存器",access:"读写",generic:true),
        RegisterDefinition(peripheral:"TIM",name:"TIM2_CNT",address:"0x40000024",purpose:"计数器",access:"读写",generic:true),
        RegisterDefinition(peripheral:"TIM",name:"TIM2_PSC",address:"0x40000028",purpose:"预分频",access:"读写",generic:true),
        RegisterDefinition(peripheral:"TIM",name:"TIM2_ARR",address:"0x4000002C",purpose:"自动重装载",access:"读写",generic:true),
        RegisterDefinition(peripheral:"ADC",name:"ADC1_ISR",address:"0x50000000",purpose:"状态寄存器",access:"读写",generic:true),
        RegisterDefinition(peripheral:"ADC",name:"ADC1_CR",address:"0x50000008",purpose:"控制寄存器",access:"读写",generic:true),
        RegisterDefinition(peripheral:"ADC",name:"ADC1_DR",address:"0x50000040",purpose:"转换数据",access:"只读",generic:true),
        RegisterDefinition(peripheral:"RCC",name:"RCC_AHB2ENR",address:"0x4002104C",purpose:"AHB2 外设时钟使能",access:"读写",generic:true),
        RegisterDefinition(peripheral:"RCC",name:"RCC_APB1ENR1",address:"0x40021058",purpose:"APB1 外设时钟使能",access:"读写",generic:true),
        RegisterDefinition(peripheral:"EXTI",name:"EXTI_IMR1",address:"0x40010400",purpose:"中断屏蔽",access:"读写",generic:true),
        RegisterDefinition(peripheral:"EXTI",name:"EXTI_RPR1",address:"0x4001040C",purpose:"上升沿挂起",access:"读写",generic:true),
        RegisterDefinition(peripheral:"NVIC",name:"NVIC_ISER0",address:"0xE000E100",purpose:"中断使能",access:"读写",generic:true),
        RegisterDefinition(peripheral:"NVIC",name:"SCB_ICSR",address:"0xE000ED04",purpose:"系统控制状态",access:"读写",generic:true)
    ] + g4Extra + g4Instances

    // F1 GPIO ports are spaced by 0x400. The catalog includes the full
    // common range; a specific MCU may physically omit some higher ports.
    private static let f1GPIO: [RegisterDefinition] = {
        let ports = Array("ABCDEFG")
        return ports.enumerated().flatMap { index, port in
            let base = 0x40010800 + index * 0x400
            return [
                RegisterDefinition(peripheral:"GPIO", name:"GPIO\(port)_CRL", address:String(format:"0x%08X", base), purpose:"端口配置低 8 位", access:"读写", generic:false),
                RegisterDefinition(peripheral:"GPIO", name:"GPIO\(port)_CRH", address:String(format:"0x%08X", base + 0x04), purpose:"端口配置高 8 位", access:"读写", generic:false),
                RegisterDefinition(peripheral:"GPIO", name:"GPIO\(port)_IDR", address:String(format:"0x%08X", base + 0x08), purpose:"输入数据", access:"只读", generic:true),
                RegisterDefinition(peripheral:"GPIO", name:"GPIO\(port)_ODR", address:String(format:"0x%08X", base + 0x0C), purpose:"输出数据", access:"读写", generic:true),
                RegisterDefinition(peripheral:"GPIO", name:"GPIO\(port)_BSRR", address:String(format:"0x%08X", base + 0x10), purpose:"置位/复位输出", access:"只写", generic:true),
                RegisterDefinition(peripheral:"GPIO", name:"GPIO\(port)_BRR", address:String(format:"0x%08X", base + 0x14), purpose:"复位输出", access:"只写", generic:true)
            ]
        }
    }()

    // G4 GPIO ports use the STM32G4 AHB2 GPIO block layout.
    private static let g4GPIO: [RegisterDefinition] = {
        let ports = Array("ABCDEFGH")
        return ports.enumerated().flatMap { index, port in
            let base = 0x48000000 + index * 0x400
            return [
                RegisterDefinition(peripheral:"GPIO", name:"GPIO\(port)_MODER", address:String(format:"0x%08X", base), purpose:"模式配置", access:"读写", generic:false),
                RegisterDefinition(peripheral:"GPIO", name:"GPIO\(port)_OTYPER", address:String(format:"0x%08X", base + 0x04), purpose:"输出类型", access:"读写", generic:false),
                RegisterDefinition(peripheral:"GPIO", name:"GPIO\(port)_OSPEEDR", address:String(format:"0x%08X", base + 0x08), purpose:"输出速度", access:"读写", generic:false),
                RegisterDefinition(peripheral:"GPIO", name:"GPIO\(port)_PUPDR", address:String(format:"0x%08X", base + 0x0C), purpose:"上下拉配置", access:"读写", generic:false),
                RegisterDefinition(peripheral:"GPIO", name:"GPIO\(port)_IDR", address:String(format:"0x%08X", base + 0x10), purpose:"输入数据", access:"只读", generic:true),
                RegisterDefinition(peripheral:"GPIO", name:"GPIO\(port)_ODR", address:String(format:"0x%08X", base + 0x14), purpose:"输出数据", access:"读写", generic:true),
                RegisterDefinition(peripheral:"GPIO", name:"GPIO\(port)_BSRR", address:String(format:"0x%08X", base + 0x18), purpose:"置位/复位输出", access:"只写", generic:true),
                RegisterDefinition(peripheral:"GPIO", name:"GPIO\(port)_LCKR", address:String(format:"0x%08X", base + 0x1C), purpose:"配置锁定", access:"读写", generic:true),
                RegisterDefinition(peripheral:"GPIO", name:"GPIO\(port)_AFRL", address:String(format:"0x%08X", base + 0x20), purpose:"复用功能低 8 位", access:"读写", generic:false),
                RegisterDefinition(peripheral:"GPIO", name:"GPIO\(port)_AFRH", address:String(format:"0x%08X", base + 0x24), purpose:"复用功能高 8 位", access:"读写", generic:false)
            ]
        }
    }()

    private static let f1Extra: [RegisterDefinition] = [
        RegisterDefinition(peripheral:"USART",name:"USART1_CR2",address:"0x40013810",purpose:"控制寄存器 2",access:"读写",generic:true),
        RegisterDefinition(peripheral:"USART",name:"USART1_CR3",address:"0x40013814",purpose:"控制寄存器 3",access:"读写",generic:true),
        RegisterDefinition(peripheral:"USART",name:"USART1_GTPR",address:"0x40013818",purpose:"保护时间和预分频",access:"读写",generic:true),
        RegisterDefinition(peripheral:"SPI",name:"SPI1_CR1",address:"0x40013000",purpose:"控制寄存器 1",access:"读写",generic:true),
        RegisterDefinition(peripheral:"SPI",name:"SPI1_CR2",address:"0x40013004",purpose:"控制寄存器 2",access:"读写",generic:true),
        RegisterDefinition(peripheral:"I2C",name:"I2C1_CR1",address:"0x40005400",purpose:"控制寄存器 1",access:"读写",generic:true),
        RegisterDefinition(peripheral:"I2C",name:"I2C1_CR2",address:"0x40005404",purpose:"控制寄存器 2",access:"读写",generic:true),
        RegisterDefinition(peripheral:"I2C",name:"I2C1_OAR1",address:"0x40005408",purpose:"自身地址 1",access:"读写",generic:true),
        RegisterDefinition(peripheral:"I2C",name:"I2C1_CCR",address:"0x4000541C",purpose:"时钟控制",access:"读写",generic:true),
        RegisterDefinition(peripheral:"I2C",name:"I2C1_TRISE",address:"0x40005420",purpose:"上升时间",access:"读写",generic:true),
        RegisterDefinition(peripheral:"DMA",name:"DMA1_ISR",address:"0x40020000",purpose:"中断状态",access:"只读",generic:true),
        RegisterDefinition(peripheral:"DMA",name:"DMA1_IFCR",address:"0x40020004",purpose:"中断标志清除",access:"只写",generic:true),
        RegisterDefinition(peripheral:"TIM",name:"TIM2_DIER",address:"0x4000000C",purpose:"DMA/中断使能",access:"读写",generic:true),
        RegisterDefinition(peripheral:"TIM",name:"TIM2_EGR",address:"0x40000014",purpose:"事件产生",access:"只写",generic:true),
        RegisterDefinition(peripheral:"TIM",name:"TIM2_CCR1",address:"0x40000034",purpose:"捕获比较 1",access:"读写",generic:true),
        RegisterDefinition(peripheral:"ADC",name:"ADC1_CR1",address:"0x40012404",purpose:"控制寄存器 1",access:"读写",generic:true),
        RegisterDefinition(peripheral:"ADC",name:"ADC1_SMPR1",address:"0x4001240C",purpose:"采样时间 1",access:"读写",generic:true),
        RegisterDefinition(peripheral:"ADC",name:"ADC1_SMPR2",address:"0x40012410",purpose:"采样时间 2",access:"读写",generic:true),
        RegisterDefinition(peripheral:"ADC",name:"ADC1_SQR1",address:"0x4001242C",purpose:"规则序列 1",access:"读写",generic:true),
        RegisterDefinition(peripheral:"RCC",name:"RCC_CR",address:"0x40021000",purpose:"时钟控制",access:"读写",generic:true),
        RegisterDefinition(peripheral:"RCC",name:"RCC_CFGR",address:"0x40021004",purpose:"时钟配置",access:"读写",generic:true),
        RegisterDefinition(peripheral:"EXTI",name:"EXTI_RTSR",address:"0x40010408",purpose:"上升沿触发选择",access:"读写",generic:true),
        RegisterDefinition(peripheral:"EXTI",name:"EXTI_FTSR",address:"0x4001040C",purpose:"下降沿触发选择",access:"读写",generic:true),
        RegisterDefinition(peripheral:"NVIC",name:"NVIC_ICER0",address:"0xE000E180",purpose:"中断清除使能",access:"读写",generic:true),
        RegisterDefinition(peripheral:"NVIC",name:"NVIC_IPR0",address:"0xE000E400",purpose:"中断优先级",access:"读写",generic:true)
    ]

    private static let g4Extra: [RegisterDefinition] = [
        RegisterDefinition(peripheral:"USART",name:"USART1_CR1",address:"0x40013800",purpose:"控制寄存器 1",access:"读写",generic:true),
        RegisterDefinition(peripheral:"USART",name:"USART1_CR2",address:"0x40013804",purpose:"控制寄存器 2",access:"读写",generic:true),
        RegisterDefinition(peripheral:"USART",name:"USART1_CR3",address:"0x40013808",purpose:"控制寄存器 3",access:"读写",generic:true),
        RegisterDefinition(peripheral:"SPI",name:"SPI1_CR1",address:"0x40013000",purpose:"控制寄存器 1",access:"读写",generic:true),
        RegisterDefinition(peripheral:"SPI",name:"SPI1_CR2",address:"0x40013004",purpose:"控制寄存器 2",access:"读写",generic:true),
        RegisterDefinition(peripheral:"SPI",name:"SPI1_CFG1",address:"0x40013008",purpose:"配置寄存器 1",access:"读写",generic:true),
        RegisterDefinition(peripheral:"SPI",name:"SPI1_CFG2",address:"0x4001300C",purpose:"配置寄存器 2",access:"读写",generic:true),
        RegisterDefinition(peripheral:"I2C",name:"I2C1_CR1",address:"0x40005400",purpose:"控制寄存器 1",access:"读写",generic:true),
        RegisterDefinition(peripheral:"I2C",name:"I2C1_CR2",address:"0x40005404",purpose:"传输配置",access:"读写",generic:true),
        RegisterDefinition(peripheral:"I2C",name:"I2C1_TIMINGR",address:"0x40005410",purpose:"时序配置",access:"读写",generic:true),
        RegisterDefinition(peripheral:"I2C",name:"I2C1_OAR1",address:"0x40005408",purpose:"自身地址 1",access:"读写",generic:true),
        RegisterDefinition(peripheral:"DMA",name:"DMA1_ISR",address:"0x40020000",purpose:"中断状态",access:"只读",generic:true),
        RegisterDefinition(peripheral:"DMA",name:"DMA1_IFCR",address:"0x40020004",purpose:"中断标志清除",access:"只写",generic:true),
        RegisterDefinition(peripheral:"TIM",name:"TIM2_DIER",address:"0x4000000C",purpose:"DMA/中断使能",access:"读写",generic:true),
        RegisterDefinition(peripheral:"TIM",name:"TIM2_EGR",address:"0x40000014",purpose:"事件产生",access:"只写",generic:true),
        RegisterDefinition(peripheral:"TIM",name:"TIM2_CCR1",address:"0x40000034",purpose:"捕获比较 1",access:"读写",generic:true),
        RegisterDefinition(peripheral:"ADC",name:"ADC1_CFGR",address:"0x5000000C",purpose:"转换配置",access:"读写",generic:true),
        RegisterDefinition(peripheral:"ADC",name:"ADC1_SMPR1",address:"0x50000014",purpose:"采样时间 1",access:"读写",generic:true),
        RegisterDefinition(peripheral:"ADC",name:"ADC1_SQR1",address:"0x50000030",purpose:"规则序列 1",access:"读写",generic:true),
        RegisterDefinition(peripheral:"RCC",name:"RCC_CR",address:"0x40021000",purpose:"时钟控制",access:"读写",generic:true),
        RegisterDefinition(peripheral:"RCC",name:"RCC_CFGR",address:"0x40021008",purpose:"时钟配置",access:"读写",generic:true),
        RegisterDefinition(peripheral:"EXTI",name:"EXTI_RTSR1",address:"0x40010408",purpose:"上升沿触发选择",access:"读写",generic:true),
        RegisterDefinition(peripheral:"EXTI",name:"EXTI_FTSR1",address:"0x4001040C",purpose:"下降沿触发选择",access:"读写",generic:true),
        RegisterDefinition(peripheral:"NVIC",name:"NVIC_ICER0",address:"0xE000E180",purpose:"中断清除使能",access:"读写",generic:true),
        RegisterDefinition(peripheral:"NVIC",name:"NVIC_IPR0",address:"0xE000E400",purpose:"中断优先级",access:"读写",generic:true)
    ]

    private static let f1Instances: [RegisterDefinition] = {
        var result: [RegisterDefinition] = []
        let usarts: [(String, Int)] = [("USART2", 0x40004400), ("USART3", 0x40004800), ("UART4", 0x40004C00), ("UART5", 0x40005000)]
        for (name, base) in usarts {
            result += [
                RegisterDefinition(peripheral:"USART", name:"\(name)_SR", address:String(format:"0x%08X", base), purpose:"状态寄存器", access:"只读", generic:true),
                RegisterDefinition(peripheral:"USART", name:"\(name)_DR", address:String(format:"0x%08X", base + 0x04), purpose:"数据寄存器", access:"读写", generic:true),
                RegisterDefinition(peripheral:"USART", name:"\(name)_BRR", address:String(format:"0x%08X", base + 0x08), purpose:"波特率", access:"读写", generic:true),
                RegisterDefinition(peripheral:"USART", name:"\(name)_CR1", address:String(format:"0x%08X", base + 0x0C), purpose:"控制寄存器 1", access:"读写", generic:true)
            ]
        }
        let spi: [(String, Int)] = [("SPI2", 0x40003800), ("SPI3", 0x40003C00)]
        for (name, base) in spi {
            result += [
                RegisterDefinition(peripheral:"SPI", name:"\(name)_CR1", address:String(format:"0x%08X", base), purpose:"控制寄存器 1", access:"读写", generic:true),
                RegisterDefinition(peripheral:"SPI", name:"\(name)_CR2", address:String(format:"0x%08X", base + 0x04), purpose:"控制寄存器 2", access:"读写", generic:true),
                RegisterDefinition(peripheral:"SPI", name:"\(name)_SR", address:String(format:"0x%08X", base + 0x08), purpose:"状态寄存器", access:"只读", generic:true),
                RegisterDefinition(peripheral:"SPI", name:"\(name)_DR", address:String(format:"0x%08X", base + 0x0C), purpose:"数据寄存器", access:"读写", generic:true)
            ]
        }
        let i2c: [(String, Int)] = [("I2C2", 0x40005800)]
        for (name, base) in i2c {
            result += [
                RegisterDefinition(peripheral:"I2C", name:"\(name)_CR1", address:String(format:"0x%08X", base), purpose:"控制寄存器 1", access:"读写", generic:true),
                RegisterDefinition(peripheral:"I2C", name:"\(name)_CR2", address:String(format:"0x%08X", base + 0x04), purpose:"控制寄存器 2", access:"读写", generic:true),
                RegisterDefinition(peripheral:"I2C", name:"\(name)_SR1", address:String(format:"0x%08X", base + 0x14), purpose:"状态寄存器 1", access:"只读", generic:true),
                RegisterDefinition(peripheral:"I2C", name:"\(name)_DR", address:String(format:"0x%08X", base + 0x10), purpose:"数据寄存器", access:"读写", generic:true)
            ]
        }
        let timers: [(String, Int)] = [("TIM1", 0x40012C00), ("TIM3", 0x40000400), ("TIM4", 0x40000800)]
        for (name, base) in timers {
            result += [
                RegisterDefinition(peripheral:"TIM", name:"\(name)_CR1", address:String(format:"0x%08X", base), purpose:"控制寄存器 1", access:"读写", generic:true),
                RegisterDefinition(peripheral:"TIM", name:"\(name)_DIER", address:String(format:"0x%08X", base + 0x0C), purpose:"DMA/中断使能", access:"读写", generic:true),
                RegisterDefinition(peripheral:"TIM", name:"\(name)_SR", address:String(format:"0x%08X", base + 0x10), purpose:"状态寄存器", access:"读写", generic:true),
                RegisterDefinition(peripheral:"TIM", name:"\(name)_CNT", address:String(format:"0x%08X", base + 0x24), purpose:"计数器", access:"读写", generic:true),
                RegisterDefinition(peripheral:"TIM", name:"\(name)_ARR", address:String(format:"0x%08X", base + 0x2C), purpose:"自动重装载", access:"读写", generic:true)
            ]
        }
        for (index, name) in [(0, "ADC1"), (1, "ADC2")] {
            let base = 0x40012400 + index * 0x400
            result += [
                RegisterDefinition(peripheral:"ADC", name:"\(name)_SR", address:String(format:"0x%08X", base), purpose:"状态寄存器", access:"读写", generic:true),
                RegisterDefinition(peripheral:"ADC", name:"\(name)_CR2", address:String(format:"0x%08X", base + 0x08), purpose:"控制寄存器 2", access:"读写", generic:true),
                RegisterDefinition(peripheral:"ADC", name:"\(name)_DR", address:String(format:"0x%08X", base + 0x4C), purpose:"转换数据", access:"只读", generic:true)
            ]
        }
        for channel in 2...7 {
            let base = 0x40020000 + (channel - 1) * 0x14
            result += [RegisterDefinition(peripheral:"DMA", name:"DMA1_CCR\(channel)", address:String(format:"0x%08X", base + 0x08), purpose:"通道配置", access:"读写", generic:true), RegisterDefinition(peripheral:"DMA", name:"DMA1_CNDTR\(channel)", address:String(format:"0x%08X", base + 0x0C), purpose:"剩余传输数量", access:"读写", generic:true)]
        }
        return result
    }()

    private static let g4Instances: [RegisterDefinition] = {
        var result: [RegisterDefinition] = []
        let usarts: [(String, Int)] = [("USART2", 0x40004400), ("USART3", 0x40004800), ("UART4", 0x40004C00), ("UART5", 0x40005000)]
        for (name, base) in usarts {
            result += [
                RegisterDefinition(peripheral:"USART", name:"\(name)_CR1", address:String(format:"0x%08X", base), purpose:"控制寄存器 1", access:"读写", generic:true),
                RegisterDefinition(peripheral:"USART", name:"\(name)_BRR", address:String(format:"0x%08X", base + 0x0C), purpose:"波特率", access:"读写", generic:true),
                RegisterDefinition(peripheral:"USART", name:"\(name)_ISR", address:String(format:"0x%08X", base + 0x1C), purpose:"中断与状态", access:"只读", generic:true),
                RegisterDefinition(peripheral:"USART", name:"\(name)_RDR", address:String(format:"0x%08X", base + 0x24), purpose:"接收数据", access:"只读", generic:true),
                RegisterDefinition(peripheral:"USART", name:"\(name)_TDR", address:String(format:"0x%08X", base + 0x28), purpose:"发送数据", access:"只写", generic:true)
            ]
        }
        let spi: [(String, Int)] = [("SPI2", 0x40003800), ("SPI3", 0x40003C00)]
        for (name, base) in spi {
            result += [
                RegisterDefinition(peripheral:"SPI", name:"\(name)_CR1", address:String(format:"0x%08X", base), purpose:"控制寄存器 1", access:"读写", generic:true),
                RegisterDefinition(peripheral:"SPI", name:"\(name)_SR", address:String(format:"0x%08X", base + 0x08), purpose:"状态寄存器", access:"只读", generic:true),
                RegisterDefinition(peripheral:"SPI", name:"\(name)_TXDR", address:String(format:"0x%08X", base + 0x20), purpose:"发送数据", access:"读写", generic:true),
                RegisterDefinition(peripheral:"SPI", name:"\(name)_RXDR", address:String(format:"0x%08X", base + 0x30), purpose:"接收数据", access:"只读", generic:true)
            ]
        }
        let i2c: [(String, Int)] = [("I2C2", 0x40005800), ("I2C3", 0x40005C00)]
        for (name, base) in i2c {
            result += [
                RegisterDefinition(peripheral:"I2C", name:"\(name)_CR1", address:String(format:"0x%08X", base), purpose:"控制寄存器 1", access:"读写", generic:true),
                RegisterDefinition(peripheral:"I2C", name:"\(name)_ISR", address:String(format:"0x%08X", base + 0x18), purpose:"状态寄存器", access:"只读", generic:true),
                RegisterDefinition(peripheral:"I2C", name:"\(name)_TXDR", address:String(format:"0x%08X", base + 0x28), purpose:"发送数据", access:"读写", generic:true),
                RegisterDefinition(peripheral:"I2C", name:"\(name)_RXDR", address:String(format:"0x%08X", base + 0x24), purpose:"接收数据", access:"只读", generic:true)
            ]
        }
        let timers: [(String, Int)] = [("TIM1", 0x40012C00), ("TIM3", 0x40000400), ("TIM4", 0x40000800), ("TIM6", 0x40001000), ("TIM7", 0x40001400), ("TIM15", 0x40014000), ("TIM16", 0x40014400), ("TIM17", 0x40014800)]
        for (name, base) in timers {
            result += [
                RegisterDefinition(peripheral:"TIM", name:"\(name)_CR1", address:String(format:"0x%08X", base), purpose:"控制寄存器 1", access:"读写", generic:true),
                RegisterDefinition(peripheral:"TIM", name:"\(name)_DIER", address:String(format:"0x%08X", base + 0x0C), purpose:"DMA/中断使能", access:"读写", generic:true),
                RegisterDefinition(peripheral:"TIM", name:"\(name)_SR", address:String(format:"0x%08X", base + 0x10), purpose:"状态寄存器", access:"读写", generic:true),
                RegisterDefinition(peripheral:"TIM", name:"\(name)_CNT", address:String(format:"0x%08X", base + 0x24), purpose:"计数器", access:"读写", generic:true),
                RegisterDefinition(peripheral:"TIM", name:"\(name)_ARR", address:String(format:"0x%08X", base + 0x2C), purpose:"自动重装载", access:"读写", generic:true)
            ]
        }
        for channel in 2...8 {
            let base = 0x40020000 + (channel - 1) * 0x14
            result += [RegisterDefinition(peripheral:"DMA", name:"DMA1_CCR\(channel)", address:String(format:"0x%08X", base + 0x08), purpose:"通道配置", access:"读写", generic:true), RegisterDefinition(peripheral:"DMA", name:"DMA1_CNDTR\(channel)", address:String(format:"0x%08X", base + 0x0C), purpose:"剩余传输数量", access:"读写", generic:true)]
        }
        return result
    }()

    private static func isAvailable(_ name: String, family: String, model: String) -> Bool {
        guard !model.isEmpty else { return true }
        let upper = model.uppercased()
        if name.hasPrefix("GPIO") {
            let port = name.dropFirst(4).prefix(1)
            if family.hasPrefix("STM32F1") && (upper.contains("F103C8") || upper.contains("F103C6")) { return "ABCD".contains(port) }
            if family.hasPrefix("STM32F1") && (upper.contains("F103R") || upper.contains("F103V") || upper.contains("F103Z")) { return "ABCDEFG".contains(port) }
            if family.hasPrefix("STM32G4") { return "ABCDEF".contains(port) }
        }
        if family.hasPrefix("STM32F1") && (upper.contains("F103C8") || upper.contains("F103C6")) {
            if name.hasPrefix("UART4") || name.hasPrefix("UART5") || name.hasPrefix("SPI3") { return false }
        }
        if family.hasPrefix("STM32G4") && upper.contains("G431") {
            if name.hasPrefix("I2C3") { return false }
        }
        return true
    }
}

struct RegisterView: View {
    @ObservedObject var studio: Studio
    @ObservedObject var debug: DebugSession
    @State private var category = "GPIO"
    @State private var instance = "全部"
    @State private var filter = ""
    @State private var lastReadRegister = ""
    let categories = ["GPIO", "USART", "I2C", "SPI", "DMA", "TIM", "ADC", "RCC", "EXTI", "NVIC"]
    var allRows: [RegisterDefinition] {
        RegisterCatalog.registers(family: studio.settings.chipFamily, model: studio.settings.chipModel).filter { $0.peripheral == category }
    }
    var instances: [String] {
        ["全部"] + Array(Set(allRows.map { instanceName($0.name) }.filter { !$0.isEmpty && $0 != "通用" })).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    var rows: [RegisterDefinition] {
        allRows.filter { (instance == "全部" || instanceName($0.name) == instance) && (filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter)) }
    }
    func instanceName(_ name: String) -> String {
        let chars = Array(name)
        var end = 0
        while end < chars.count && (chars[end].isLetter || chars[end] == "_") { end += 1 }
        var numberEnd = end
        while numberEnd < chars.count && chars[numberEnd].isNumber { numberEnd += 1 }
        if numberEnd > end { return String(chars[0..<numberEnd]) }
        if name.hasPrefix("GPIO") && chars.count >= 5 { return String(chars[0..<5]) }
        return "通用"
    }
    var body: some View {
        ScrollView { VStack(alignment:.leading,spacing:16) {
            Card(title:"常用寄存器助手",icon:"list.bullet.rectangle") {
                Text("当前型号：\(studio.settings.chipModel.isEmpty ? "未选择" : studio.settings.chipModel) · \(studio.settings.chipFamily.isEmpty ? "通用定义" : studio.settings.chipFamily)").font(.callout)
                Text("仅提供只读查看。F1/G4 使用各自地址表；标记“通用”的寄存器名称相近，但仍应以当前型号参考手册或 SVD 为准。").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Picker("外设",selection:$category) { ForEach(categories,id:\.self) { Text($0).tag($0) } }.pickerStyle(.segmented).onChange(of: category) { _ in instance = "全部" }
                    TextField("搜索寄存器",text:$filter).textFieldStyle(.roundedBorder).frame(width:220)
                }
                ScrollView(.horizontal, showsIndicators:false) {
                    Picker("接口实例",selection:$instance) { ForEach(instances,id:\.self) { Text($0).tag($0) } }.pickerStyle(.segmented).fixedSize(horizontal:false,vertical:true)
                }
            }
            Card(title:"\(category) 常用寄存器",icon:"cpu") {
                if rows.isEmpty { Text("当前系列暂未建立该外设的寄存器表。").foregroundStyle(.secondary) }
                ForEach(rows) { reg in
                    VStack(alignment:.leading,spacing:6) {
                        HStack(spacing:10) {
                            VStack(alignment:.leading,spacing:3) { Text(reg.name).font(.system(.body,design:.monospaced)); Text("\(reg.address) · \(reg.purpose) · \(reg.access)").font(.caption).foregroundStyle(.secondary); if !reg.available { Text("当前型号不存在").font(.caption).foregroundStyle(.tertiary) } }
                            Spacer()
                            if reg.generic { Text("通用").font(.caption).foregroundStyle(.secondary) }
                            Button("读取") { lastReadRegister = reg.name; debug.readRegister(reg) }.disabled(!reg.available || !debug.connected || debug.running).opacity(reg.available ? 1 : 0.45)
                        }
                        if lastReadRegister == reg.name {
                            Text(debug.registerOutput.isEmpty ? "正在读取…" : debug.registerOutput)
                                .font(.system(size:12,design:.monospaced))
                                .textSelection(.enabled)
                                .padding(.leading,8)
                                .foregroundStyle(.secondary)
                        }
                    }.padding(.vertical,5)
                    Divider()
                }
                if lastReadRegister.isEmpty { Text("连接并暂停调试后，点击“读取”查看当前值。").font(.caption).foregroundStyle(.secondary) }
            }
        }.padding(24) }
    }
}
