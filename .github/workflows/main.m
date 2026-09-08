#import <Foundation/Foundation.h>

// Hàm constructor này tự động chạy NGAY LẬP TỨC khi dylib được nạp vào App
__attribute__((constructor))
static void initialize(void) {
    @autoreleasepool {
        // Lấy Bundle ID của app đang chạy
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        
        // Chỉ chạy nếu đúng ứng dụng com.lordex.ios
        if ([bundleID isEqualToString:@"com.dts.freefireth"]) {
            
            // Chạy logic ở thread ngầm (Background Thread) để không ảnh hưởng đến giao diện chính
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                
                // ====================================================
                // VIẾT CODE BẠN MUỐN CHẠY NGẦM Ở ĐÂY
                // (Ví dụ: Hooking, gửi request API, chỉnh sửa memory...)
                // ====================================================
                
            });
        }
    }
}
