use arboard::{Clipboard,ClipboardData,ClipboardFormat,ImageData};
use std::{ffi::c_void,ptr,thread,time::Duration};
type Handle=isize;
#[link(name="user32")]
extern "system" {
 fn CreateWindowExW(ex:u32,class:*const u16,title:*const u16,style:u32,x:i32,y:i32,w:i32,h:i32,parent:Handle,menu:Handle,instance:Handle,param:*const c_void)->Handle;
 fn OpenClipboard(window:Handle)->i32;
 fn CloseClipboard()->i32;
 fn EmptyClipboard()->i32;
 fn SetClipboardData(format:u32,data:Handle)->Handle;
 fn GetClipboardData(format:u32)->Handle;
 fn RegisterClipboardFormatW(name:*const u16)->u32;
}
#[link(name="kernel32")]
extern "system" {
 fn GlobalAlloc(flags:u32,size:usize)->Handle;
 fn GlobalLock(memory:Handle)->*mut c_void;
 fn GlobalUnlock(memory:Handle)->i32;
 fn GlobalSize(memory:Handle)->usize;
}
fn wide(s:&str)->Vec<u16>{s.encode_utf16().chain(Some(0)).collect()}
fn publish(window:Handle,format:u32,data:&[u8]) {
 unsafe {
  assert_ne!(OpenClipboard(window),0);assert_ne!(EmptyClipboard(),0);
  let memory=GlobalAlloc(0x42,data.len());assert_ne!(memory,0);
  let p=GlobalLock(memory);assert!(!p.is_null());ptr::copy_nonoverlapping(data.as_ptr(),p as *mut u8,data.len());GlobalUnlock(memory);
  assert_ne!(SetClipboardData(format,memory),0);assert_ne!(CloseClipboard(),0);
 }
}
fn sample()->Vec<u8>{(0..17*13).flat_map(|i|[(i*13%256) as u8,(i*7%256) as u8,(i*3%256) as u8,255]).collect()}
fn dib(bits:u16)->Vec<u8>{
 let row=((17*usize::from(bits)+31)/32)*4;let mut data=vec![0;40+row*13];
 data[0..4].copy_from_slice(&40u32.to_le_bytes());data[4..8].copy_from_slice(&17i32.to_le_bytes());data[8..12].copy_from_slice(&13i32.to_le_bytes());data[12..14].copy_from_slice(&1u16.to_le_bytes());data[14..16].copy_from_slice(&bits.to_le_bytes());
 let expected=sample();
 for y in 0..13 {for x in 0..17 {let src=(y*17+x)*4;let dest=40+(12-y)*row+x*usize::from(bits)/8;data[dest..dest+3].copy_from_slice(&[expected[src+2],expected[src+1],expected[src]]);}}
 data
}
fn read_image(board:&mut Clipboard)->bool {
 match board.get_formats(&[ClipboardFormat::ImageRgba,ClipboardFormat::ImagePng]) {
  Ok(values)=>values.iter().any(|v|match v {ClipboardData::Image(ImageData::Rgba(a))=>a.width==17 && a.height==13 && a.bytes.as_ref()==sample(),ClipboardData::Image(ImageData::Png(p))=>!p.is_empty(),_=>false}),
  Err(_)=>false,
 }
}
fn main(){
 assert_eq!(std::env::var("GITHUB_ACTIONS").as_deref(),Ok("true"),"Only an isolated hosted runner may write its clipboard");
 let window=unsafe{CreateWindowExW(0,wide("STATIC").as_ptr(),wide("g3 clipboard QA").as_ptr(),0,0,0,1,1,0,0,0,ptr::null())};assert_ne!(window,0);
 let mut board=Clipboard::new().expect("isolated clipboard");
 publish(window,8,&dib(24));let dib24=read_image(&mut board);
 publish(window,8,&dib(32));let dib32=read_image(&mut board);
 board.set_image(ImageData::rgba(17,13,sample().into())).expect("synthetic RGBA");let rgba=read_image(&mut board);
 let png_format=unsafe{RegisterClipboardFormatW(wide("image/png").as_ptr())};
 let png=unsafe{assert_ne!(OpenClipboard(window),0);let memory=GetClipboardData(png_format);assert_ne!(memory,0);let len=GlobalSize(memory);let p=GlobalLock(memory);assert!(!p.is_null());let copy=std::slice::from_raw_parts(p as *const u8,len).to_vec();GlobalUnlock(memory);CloseClipboard();copy};
 publish(window,png_format,&png);let png_only=read_image(&mut board);
 let greenshot_format=unsafe{RegisterClipboardFormatW(wide("PNG").as_ptr())};publish(window,greenshot_format,&png);let greenshot_png=read_image(&mut board);
 publish(window,8,&dib(24));
 let (tx,rx)=std::sync::mpsc::channel();
 let held=thread::spawn(move||{unsafe{assert_ne!(OpenClipboard(window),0)};tx.send(()).expect("lock signal");thread::sleep(Duration::from_millis(300));unsafe{CloseClipboard()};});rx.recv().expect("lock ready");
 let mut busy_recovered=false;for _ in 0..3 {if read_image(&mut board){busy_recovered=true;break;}thread::sleep(Duration::from_millis(33));}
 held.join().expect("lock release");let after_release=read_image(&mut board);
 let report=format!("{{\"dib24_rgba_exact\":{dib24},\"dib32_zero_alpha_rgba_exact\":{dib32},\"rgba_roundtrip\":{rgba},\"png_only_readable\":{png_only},\"greenshot_png_format_readable\":{greenshot_png},\"three_short_retries_recover_300ms_lock\":{busy_recovered},\"image_readable_after_lock_release\":{after_release},\"production_clipboards_touched\":false}}");
 println!("{report}");std::fs::write("clipboard-format-evidence.json",&report).expect("evidence");
 if !(dib24&&dib32&&rgba&&png_only&&after_release){std::process::exit(1)}
}
