import {search} from "./rules.mjs";
self.onmessage=({data})=>{try{self.postMessage({id:data.id,...search(data.position,data.options)})}catch(error){self.postMessage({id:data.id,error:error.message,action:{kind:"pass",point:0}})}};
